import { WebSocketServer, WebSocket } from "ws";

/**
 * Signaling server: introduces two devices so they can open a direct WebRTC
 * connection. It forwards opaque setup messages between connected devices and
 * never sees screen content or input.
 *
 * Client → server
 *   { type: "hello", id }               must be the first message
 *   { type: "signal", to, data }        forward `data` to device `to`
 * Server → client
 *   { type: "welcome" }
 *   { type: "signal", from, data }
 *   { type: "error", code, to? }        codes: offline, bad-message, bad-id, hello-timeout
 */

const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_MESSAGE_BYTES = 64 * 1024;
const HELLO_TIMEOUT_MS = 5_000;
const PING_INTERVAL_MS = 30_000;

/** Application close codes (4000–4999 are free for private use). */
export const CLOSE = {
  protocol: 4000,
  replaced: 4001,
  helloTimeout: 4002,
} as const;

export interface SignalingServerOptions {
  port: number;
  host?: string;
  log?: (line: string) => void;
}

export interface SignalingServer {
  /** The port actually bound (useful when `port` was 0). */
  port: number;
  close(): Promise<void>;
}

interface Client {
  socket: WebSocket;
  id: string | null;
  alive: boolean;
}

export function startSignalingServer(options: SignalingServerOptions): Promise<SignalingServer> {
  const log = options.log ?? (() => {});
  const devices = new Map<string, Client>();
  const wss = new WebSocketServer({
    port: options.port,
    host: options.host,
    maxPayload: MAX_MESSAGE_BYTES,
  });

  const send = (socket: WebSocket, message: object) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  };

  wss.on("connection", (socket) => {
    const client: Client = { socket, id: null, alive: true };

    const helloTimer = setTimeout(() => {
      if (client.id === null) {
        send(socket, { type: "error", code: "hello-timeout" });
        socket.close(CLOSE.helloTimeout);
      }
    }, HELLO_TIMEOUT_MS);

    const reject = (code: string) => {
      send(socket, { type: "error", code });
      socket.close(CLOSE.protocol);
    };

    socket.on("pong", () => {
      client.alive = true;
    });

    socket.on("message", (raw, isBinary) => {
      if (isBinary) return reject("bad-message");
      let message: unknown;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        return reject("bad-message");
      }
      if (typeof message !== "object" || message === null) return reject("bad-message");
      const { type, id, to, data } = message as Record<string, unknown>;

      if (client.id === null) {
        if (type !== "hello") return reject("bad-message");
        if (typeof id !== "string" || !ID_PATTERN.test(id)) return reject("bad-id");
        // A device that reconnects takes over from its stale connection.
        const previous = devices.get(id);
        if (previous) previous.socket.close(CLOSE.replaced);
        client.id = id;
        devices.set(id, client);
        clearTimeout(helloTimer);
        send(socket, { type: "welcome" });
        log(`+ ${id} (${devices.size} online)`);
        return;
      }

      if (type !== "signal" || typeof to !== "string" || typeof data !== "object" || data === null) {
        return reject("bad-message");
      }
      const target = devices.get(to);
      if (!target) return send(socket, { type: "error", code: "offline", to });
      send(target.socket, { type: "signal", from: client.id, data });
    });

    socket.on("close", () => {
      clearTimeout(helloTimer);
      if (client.id !== null && devices.get(client.id) === client) {
        devices.delete(client.id);
        log(`- ${client.id} (${devices.size} online)`);
      }
    });

    socket.on("error", () => socket.terminate());
  });

  // Drop connections that stopped answering pings (sleeping laptop, dead NAT mapping).
  const pinger = setInterval(() => {
    for (const client of devices.values()) {
      if (!client.alive) {
        client.socket.terminate();
        continue;
      }
      client.alive = false;
      client.socket.ping();
    }
  }, PING_INTERVAL_MS);
  pinger.unref();

  return new Promise((resolve, reject) => {
    wss.once("error", reject);
    wss.once("listening", () => {
      const address = wss.address();
      const port = typeof address === "object" && address !== null ? address.port : options.port;
      resolve({
        port,
        close: () =>
          new Promise<void>((done) => {
            clearInterval(pinger);
            for (const socket of wss.clients) socket.terminate();
            wss.close(() => done());
          }),
      });
    });
  });
}
