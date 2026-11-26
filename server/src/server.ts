import { createHash, createHmac, createPublicKey, randomBytes, timingSafeEqual, verify } from "node:crypto";
import { createServer, type IncomingMessage } from "node:http";
import { WebSocketServer, WebSocket } from "ws";

/**
 * Signaling server: introduces two devices so they can open a direct WebRTC
 * connection. It forwards opaque setup messages between connected devices and
 * never sees screen content or input.
 *
 * What it checks: a device must know the access token (if one is set) and must
 * prove it holds the private key its ID is derived from. What it does not
 * decide: who may control whom. That is settled end to end between paired
 * devices, so this server cannot grant itself or anyone else a session.
 *
 * Client → server
 *   { type: "hello", id, key, token? }  first message; key = base64 Ed25519 public key
 *   { type: "auth", sig }               base64 signature over `authMessage(id, nonce)`
 *   { type: "signal", to, data }        forward `data` to device `to`
 *   { type: "ice" }                     ask for STUN/TURN servers and fresh credentials
 *   { type: "pair-open", tag }          accept pairing messages addressed to `tag`
 *   { type: "pair-close" }
 *   { type: "pair", tag, data }         forward to whoever opened `tag`
 *   { type: "pair-reply", to, data }    answer a pairing message
 * Server → client
 *   { type: "challenge", nonce }
 *   { type: "welcome" }
 *   { type: "signal" | "pair" | "pair-reply", from, data }
 *   { type: "ice", servers: [{ urls, username?, credential? }] }
 *   { type: "error", code, to? }        offline, no-such-pairing, bad-message,
 *                                       bad-id, bad-token, bad-auth, hello-timeout,
 *                                       unsupported (a type this server does not know;
 *                                       the connection stays open; messageType names
 *                                       it), rate-limited
 * A connection over the connection limits is refused at the upgrade with HTTP 503.
 */

const ID_PATTERN = /^[a-z2-7]{16}$/;
const TAG_PATTERN = /^[0-9a-f]{16}$/;
const MAX_MESSAGE_BYTES = 64 * 1024;
const HELLO_TIMEOUT_MS = 5_000;
const PING_INTERVAL_MS = 30_000;
const PAIRING_LIFETIME_MS = 10 * 60_000;
/** Most device IDs one presence request may name. */
const MAX_PRESENCE_IDS = 64;

/** Defaults for `SignalingServerOptions.limits`. */
export const DEFAULT_LIMITS = {
  /** Messages a connection may send per second, on average. Signaling needs a few dozen at most. */
  messagesPerSecond: 50,
  /** Messages a connection may send in one burst. */
  burst: 100,
  /** A peer that reads too slowly is dropped once this much waits to be sent to it. */
  maxBufferedBytes: 1024 * 1024,
  maxConnections: 1000,
  maxConnectionsPerIp: 20,
} as const;

export type Limits = { -readonly [K in keyof typeof DEFAULT_LIMITS]: number };

/** Application close codes (4000–4999 are free for private use). */
export const CLOSE = {
  protocol: 4000,
  replaced: 4001,
  helloTimeout: 4002,
  unauthorized: 4003,
  rateLimited: 4004,
} as const;

export interface TurnOptions {
  /** Shared with coturn (`static-auth-secret`). */
  secret: string;
  /** e.g. ["turn:turn.example.com:3478?transport=udp"] */
  urls: string[];
  /** How long issued credentials stay valid. Default 24 h. */
  ttlSeconds?: number;
}

export interface SignalingServerOptions {
  port: number;
  host?: string;
  /** If set, devices must present it. Keeps strangers off the relay. */
  accessToken?: string;
  stunUrls?: string[];
  turn?: TurnOptions;
  log?: (line: string) => void;
  /** Rate and connection limits; anything not given takes its `DEFAULT_LIMITS` value. */
  limits?: Partial<Limits>;
  /**
   * Count connections per IP by the X-Forwarded-For header. Only for a server reachable
   * through reverse proxies alone, each of which appends the address it was reached from;
   * otherwise a client could name any address, or every client would share the proxy's.
   */
  trustProxy?: boolean;
  /** How many proxies append to X-Forwarded-For: the client is the entry this far from the end. Default 1. */
  trustProxyHops?: number;
  /** Clock, for tests. */
  now?: () => number;
}

export interface SignalingServer {
  /** The port actually bound (useful when `port` was 0). */
  port: number;
  close(): Promise<void>;
}

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/** 16 characters: first 80 bits of SHA-256(public key), RFC 4648 base32, lower case. */
export function deriveDeviceId(publicKey: Uint8Array): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  const digest = createHash("sha256").update(publicKey).digest().subarray(0, 10);
  let bits = 0;
  let buffer = 0;
  let out = "";
  for (const byte of digest) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += alphabet[(buffer >> bits) & 31];
    }
    buffer &= (1 << bits) - 1;
  }
  return out;
}

/** The bytes a device signs to log in. */
export function authMessage(id: string, nonce: string): Buffer {
  return Buffer.from(`macbridge-auth-v1|${id}|${nonce}`, "utf8");
}

/** coturn "REST API" credentials: username = expiry:id, credential = HMAC-SHA1(secret, username). */
export function turnCredentials(turn: TurnOptions, id: string, nowMs: number): IceServer {
  const expiry = Math.floor(nowMs / 1000) + (turn.ttlSeconds ?? 24 * 3600);
  const username = `${expiry}:${id}`;
  const credential = createHmac("sha1", turn.secret).update(username).digest("base64");
  return { urls: turn.urls, username, credential };
}

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function verifyEd25519(publicKey: Buffer, message: Buffer, signature: Buffer): boolean {
  try {
    const key = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, publicKey]),
      format: "der",
      type: "spki",
    });
    return verify(null, message, key, signature);
  } catch {
    return false;
  }
}

function sameSecret(a: string, b: string): boolean {
  const digest = (value: string) => createHash("sha256").update(value).digest();
  return timingSafeEqual(digest(a), digest(b));
}

interface Client {
  socket: WebSocket;
  /** Set once the device has proved it holds its key. */
  id: string | null;
  pending: { id: string; key: Buffer; nonce: string } | null;
  alive: boolean;
  pairing: { tag: string; timer: NodeJS.Timeout } | null;
  /** Token bucket: messages this connection may still send, refilled over time. */
  tokens: number;
  refilledAt: number;
}

export function startSignalingServer(options: SignalingServerOptions): Promise<SignalingServer> {
  const log = options.log ?? (() => {});
  const now = options.now ?? Date.now;
  const devices = new Map<string, Client>();
  const pairings = new Map<string, Client>();
  const limits: Limits = { ...DEFAULT_LIMITS };
  for (const [name, value] of Object.entries(options.limits ?? {}) as [keyof Limits, number | undefined][]) {
    if (value !== undefined) limits[name] = value;
  }
  const perIp = new Map<string, number>();
  let connections = 0;
  const http = createServer((_request, response) => {
    response.writeHead(426, { "Content-Type": "text/plain" }).end("Upgrade Required");
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });

  const clientAddress = (request: IncomingMessage): string => {
    const direct = request.socket.remoteAddress ?? "unknown";
    if (!options.trustProxy) return direct;
    const header = request.headers["x-forwarded-for"];
    const entries = (Array.isArray(header) ? header.join(",") : (header ?? ""))
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean);
    const hops = Math.max(1, options.trustProxyHops ?? 1);
    return entries[entries.length - hops] ?? entries[0] ?? direct;
  };

  // Limits are checked before the WebSocket exists, so a refused connection never holds a
  // slot, whatever its client does next. A slot is freed when the TCP connection closes.
  http.on("upgrade", (request, tcp, head) => {
    const ip = clientAddress(request);
    if (connections >= limits.maxConnections || (perIp.get(ip) ?? 0) >= limits.maxConnectionsPerIp) {
      tcp.once("finish", () => tcp.destroy());
      tcp.end("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    connections += 1;
    perIp.set(ip, (perIp.get(ip) ?? 0) + 1);
    tcp.once("close", () => {
      connections -= 1;
      const left = (perIp.get(ip) ?? 1) - 1;
      if (left > 0) perIp.set(ip, left);
      else perIp.delete(ip);
    });
    wss.handleUpgrade(request, tcp, head, (socket) => wss.emit("connection", socket, request));
  });

  const send = (socket: WebSocket, message: object) => {
    if (socket.readyState !== WebSocket.OPEN) return;
    // A peer that does not read would make the server hold everything sent to it.
    if (socket.bufferedAmount > limits.maxBufferedBytes) return socket.terminate();
    socket.send(JSON.stringify(message));
  };

  const closePairing = (client: Client) => {
    if (!client.pairing) return;
    clearTimeout(client.pairing.timer);
    if (pairings.get(client.pairing.tag) === client) pairings.delete(client.pairing.tag);
    client.pairing = null;
  };

  wss.on("connection", (socket: WebSocket) => {
    const client: Client = {
      socket,
      id: null,
      pending: null,
      alive: true,
      pairing: null,
      tokens: limits.burst,
      refilledAt: now(),
    };

    const helloTimer = setTimeout(() => {
      if (client.id === null) {
        send(socket, { type: "error", code: "hello-timeout" });
        socket.close(CLOSE.helloTimeout);
      }
    }, HELLO_TIMEOUT_MS);

    const reject = (code: string, closeCode: number = CLOSE.protocol) => {
      send(socket, { type: "error", code });
      socket.close(closeCode);
    };

    /** Forward `data` to a logged-in device, or report that it is offline. */
    const forward = (type: string, to: unknown, data: unknown) => {
      if (typeof to !== "string" || typeof data !== "object" || data === null) return reject("bad-message");
      const target = devices.get(to);
      if (!target) return send(socket, { type: "error", code: "offline", to });
      send(target.socket, { type, from: client.id, data });
    };

    socket.on("pong", () => {
      client.alive = true;
    });

    socket.on("message", (raw, isBinary) => {
      const time = now();
      client.tokens = Math.min(limits.burst, client.tokens + ((time - client.refilledAt) / 1000) * limits.messagesPerSecond);
      client.refilledAt = time;
      if (client.tokens < 1) return reject("rate-limited", CLOSE.rateLimited);
      client.tokens -= 1;
      if (isBinary) return reject("bad-message");
      let message: unknown;
      try {
        message = JSON.parse(raw.toString());
      } catch {
        return reject("bad-message");
      }
      if (typeof message !== "object" || message === null) return reject("bad-message");
      const { type, id, key, token, sig, to, data, tag } = message as Record<string, unknown>;

      // --- Login: hello → challenge → auth → welcome ---
      if (client.id === null) {
        if (client.pending === null) {
          if (type !== "hello") return reject("bad-message");
          if (options.accessToken !== undefined) {
            if (typeof token !== "string" || !sameSecret(token, options.accessToken)) {
              return reject("bad-token", CLOSE.unauthorized);
            }
          }
          if (typeof id !== "string" || !ID_PATTERN.test(id) || typeof key !== "string") return reject("bad-id");
          const publicKey = Buffer.from(key, "base64");
          if (publicKey.length !== 32 || deriveDeviceId(publicKey) !== id) return reject("bad-id");
          client.pending = { id, key: publicKey, nonce: randomBytes(24).toString("base64url") };
          return send(socket, { type: "challenge", nonce: client.pending.nonce });
        }

        if (type !== "auth" || typeof sig !== "string") return reject("bad-message");
        const { id: claimed, key: publicKey, nonce } = client.pending;
        if (!verifyEd25519(publicKey, authMessage(claimed, nonce), Buffer.from(sig, "base64"))) {
          return reject("bad-auth", CLOSE.unauthorized);
        }
        // A device that reconnects takes over from its stale connection.
        devices.get(claimed)?.socket.close(CLOSE.replaced);
        client.id = claimed;
        client.pending = null;
        devices.set(claimed, client);
        clearTimeout(helloTimer);
        send(socket, { type: "welcome" });
        log(`+ ${claimed} (${devices.size} online)`);
        return;
      }

      // --- Logged in ---
      switch (type) {
        case "signal":
          return forward("signal", to, data);

        case "ice": {
          const servers: IceServer[] = [];
          if (options.stunUrls?.length) servers.push({ urls: options.stunUrls });
          if (options.turn) servers.push(turnCredentials(options.turn, client.id, now()));
          return send(socket, { type: "ice", servers });
        }

        case "presence": {
          // Which of these devices are connected. Only IDs the client already knows are answered,
          // so the server never lists who is online.
          const { ids } = message as Record<string, unknown>;
          if (!Array.isArray(ids) || ids.length > MAX_PRESENCE_IDS) return reject("bad-message");
          const online: string[] = [];
          for (const one of ids) {
            if (typeof one !== "string" || !ID_PATTERN.test(one)) return reject("bad-message");
            if (devices.has(one)) online.push(one);
          }
          return send(socket, { type: "presence", online });
        }

        case "pair-open": {
          if (typeof tag !== "string" || !TAG_PATTERN.test(tag)) return reject("bad-message");
          closePairing(client);
          const timer = setTimeout(() => closePairing(client), PAIRING_LIFETIME_MS);
          timer.unref();
          client.pairing = { tag, timer };
          pairings.set(tag, client);
          return;
        }

        case "pair-close":
          return closePairing(client);

        case "pair": {
          if (typeof tag !== "string" || !TAG_PATTERN.test(tag) || typeof data !== "object" || data === null) {
            return reject("bad-message");
          }
          const target = pairings.get(tag);
          if (!target) return send(socket, { type: "error", code: "no-such-pairing" });
          return send(target.socket, { type: "pair", from: client.id, data });
        }

        case "pair-reply":
          return forward("pair-reply", to, data);

        default:
          if (typeof type !== "string" || Array.isArray(message)) return reject("bad-message");
          // A newer client may know types this server does not: say so and stay connected.
          return send(socket, { type: "error", code: "unsupported", messageType: type });
      }
    });

    socket.on("close", () => {
      clearTimeout(helloTimer);
      closePairing(client);
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
    http.once("error", reject);
    http.listen(options.port, options.host, () => {
      const address = http.address();
      const port = typeof address === "object" && address !== null ? address.port : options.port;
      resolve({
        port,
        close: () =>
          new Promise<void>((done) => {
            clearInterval(pinger);
            for (const socket of wss.clients) socket.terminate();
            wss.close();
            http.closeAllConnections();
            http.close(() => done());
          }),
      });
    });
  });
}
