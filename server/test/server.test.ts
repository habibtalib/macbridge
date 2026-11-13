import { createHmac, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocket } from "ws";
import {
  CLOSE,
  authMessage,
  deriveDeviceId,
  startSignalingServer,
  turnCredentials,
  type SignalingServer,
  type SignalingServerOptions,
} from "../src/server.ts";

let server: SignalingServer;
const sockets: WebSocket[] = [];

async function start(options: Partial<SignalingServerOptions> = {}) {
  server = await startSignalingServer({ port: 0, host: "127.0.0.1", ...options });
}

afterEach(async () => {
  for (const socket of sockets.splice(0)) socket.terminate();
  await server?.close();
});

class Identity {
  readonly privateKey: KeyObject;
  readonly publicKey: Buffer;
  readonly id: string;

  constructor() {
    const pair = generateKeyPairSync("ed25519");
    this.privateKey = pair.privateKey;
    // The last 32 bytes of the SPKI encoding are the raw key.
    this.publicKey = pair.publicKey.export({ format: "der", type: "spki" }).subarray(-32);
    this.id = deriveDeviceId(this.publicKey);
  }

  sign(nonce: string, id = this.id): string {
    return sign(null, authMessage(id, nonce), this.privateKey).toString("base64");
  }
}

/** A test client that queues incoming messages so none are missed. */
class Device {
  private queue: unknown[] = [];
  private waiters: ((message: unknown) => void)[] = [];
  readonly closed: Promise<number>;
  readonly socket: WebSocket;
  readonly identity: Identity;

  private constructor(socket: WebSocket, identity: Identity) {
    this.socket = socket;
    this.identity = identity;
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const waiter = this.waiters.shift();
      if (waiter) waiter(message);
      else this.queue.push(message);
    });
    this.closed = new Promise((resolve) => socket.on("close", (code) => resolve(code)));
  }

  get id() {
    return this.identity.id;
  }

  static async open(identity = new Identity()): Promise<Device> {
    const socket = new WebSocket(`ws://127.0.0.1:${server.port}`);
    sockets.push(socket);
    const device = new Device(socket, identity);
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", reject);
    });
    return device;
  }

  /** Full login: hello → challenge → auth → welcome. */
  static async online(options: { identity?: Identity; token?: string } = {}): Promise<Device> {
    const device = await Device.open(options.identity);
    const nonce = await device.hello(options.token);
    device.send({ type: "auth", sig: device.identity.sign(nonce) });
    expect(await device.next()).toEqual({ type: "welcome" });
    return device;
  }

  async hello(token?: string): Promise<string> {
    this.send({ type: "hello", id: this.id, key: this.identity.publicKey.toString("base64"), token });
    const challenge = (await this.next()) as { type: string; nonce: string };
    expect(challenge.type).toBe("challenge");
    return challenge.nonce;
  }

  send(message: unknown) {
    this.socket.send(typeof message === "string" ? message : JSON.stringify(message));
  }

  next(): Promise<unknown> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

describe("device ids", () => {
  it("matches the vector shared with the Swift client", () => {
    expect(deriveDeviceId(new Uint8Array(32))).toBe("mzuhvlpymk6xo3ep");
  });
});

describe("login", () => {
  it("welcomes a device that proves it holds its key", async () => {
    await start();
    await Device.online();
  });

  it("rejects a signature made with another key", async () => {
    await start();
    const device = await Device.open();
    const nonce = await device.hello();
    device.send({ type: "auth", sig: new Identity().sign(nonce, device.id) });
    expect(await device.next()).toEqual({ type: "error", code: "bad-auth" });
    expect(await device.closed).toBe(CLOSE.unauthorized);
  });

  it("rejects a signature over a different nonce", async () => {
    await start();
    const device = await Device.open();
    await device.hello();
    device.send({ type: "auth", sig: device.identity.sign("some-other-nonce") });
    expect(await device.next()).toEqual({ type: "error", code: "bad-auth" });
  });

  it("rejects an id that is not derived from the presented key", async () => {
    await start();
    const device = await Device.open();
    const other = new Identity();
    device.send({ type: "hello", id: other.id, key: device.identity.publicKey.toString("base64") });
    expect(await device.next()).toEqual({ type: "error", code: "bad-id" });
    expect(await device.closed).toBe(CLOSE.protocol);
  });

  it.each([
    { id: "", key: "" },
    { id: "has space", key: "AAAA" },
    { id: "abcdefghijklmnop", key: "not-a-key" },
    { id: 42, key: null },
  ])("rejects malformed hello %j", async (hello) => {
    await start();
    const device = await Device.open();
    device.send({ type: "hello", ...hello });
    expect(await device.next()).toEqual({ type: "error", code: "bad-id" });
  });

  it("does not relay anything before login completes", async () => {
    await start();
    const target = await Device.online();
    const device = await Device.open();
    device.send({ type: "signal", to: target.id, data: {} });
    expect(await device.next()).toEqual({ type: "error", code: "bad-message" });

    const halfway = await Device.open();
    await halfway.hello();
    halfway.send({ type: "signal", to: target.id, data: {} });
    expect(await halfway.next()).toEqual({ type: "error", code: "bad-message" });
    expect(await halfway.closed).toBe(CLOSE.protocol);
  });

  it("lets a reconnecting device replace its old connection", async () => {
    await start();
    const identity = new Identity();
    const first = await Device.online({ identity });
    const second = await Device.online({ identity });
    expect(await first.closed).toBe(CLOSE.replaced);

    const laptop = await Device.online();
    laptop.send({ type: "signal", to: identity.id, data: { kind: "request" } });
    expect(await second.next()).toMatchObject({ from: laptop.id });
  });
});

describe("access token", () => {
  const token = "correct-horse-battery-staple-0123";

  it("admits a device with the token", async () => {
    await start({ accessToken: token });
    await Device.online({ token });
  });

  it.each([undefined, "", "wrong", token + "x", 42])("turns away token %j", async (presented) => {
    await start({ accessToken: token });
    const device = await Device.open();
    device.send({
      type: "hello",
      id: device.id,
      key: device.identity.publicKey.toString("base64"),
      token: presented,
    });
    expect(await device.next()).toEqual({ type: "error", code: "bad-token" });
    expect(await device.closed).toBe(CLOSE.unauthorized);
  });
});

describe("relay", () => {
  it("forwards signals between two devices, tagging the real sender", async () => {
    await start();
    const studio = await Device.online();
    const laptop = await Device.online();

    laptop.send({ type: "signal", to: studio.id, from: "someone-else", data: { kind: "request" } });
    expect(await studio.next()).toEqual({ type: "signal", from: laptop.id, data: { kind: "request" } });

    studio.send({ type: "signal", to: laptop.id, data: { kind: "offer", sdp: "v=0" } });
    expect(await laptop.next()).toEqual({ type: "signal", from: studio.id, data: { kind: "offer", sdp: "v=0" } });
  });

  it("tells the sender when the target is offline or has left", async () => {
    await start();
    const studio = await Device.online();
    const laptop = await Device.online();
    laptop.send({ type: "signal", to: "aaaaaaaaaaaaaaaa", data: {} });
    expect(await laptop.next()).toEqual({ type: "error", code: "offline", to: "aaaaaaaaaaaaaaaa" });

    studio.socket.close();
    await studio.closed;
    laptop.send({ type: "signal", to: studio.id, data: {} });
    expect(await laptop.next()).toEqual({ type: "error", code: "offline", to: studio.id });
  });

  it.each(["not json", "[]", '"text"', '{"type":"signal","to":"x"}', '{"type":"signal","to":1,"data":{}}', '{"type":"nope"}'])(
    "rejects malformed message %s",
    async (raw) => {
      await start();
      const device = await Device.online();
      device.send(raw);
      expect(await device.next()).toEqual({ type: "error", code: "bad-message" });
      expect(await device.closed).toBe(CLOSE.protocol);
    },
  );

  it("closes connections that send oversized messages", async () => {
    await start();
    const device = await Device.online();
    device.send({ type: "signal", to: device.id, data: { blob: "x".repeat(70 * 1024) } });
    expect(await device.closed).toBe(1009);
  });
});

describe("pairing", () => {
  const tag = "0123456789abcdef";

  it("routes a pairing message by tag and the reply by id", async () => {
    await start();
    const host = await Device.online();
    const controller = await Device.online();

    host.send({ type: "pair-open", tag });
    // pair-open has no reply; a round trip through the server orders it before the next step.
    host.send({ type: "ice" });
    await host.next();

    controller.send({ type: "pair", tag, data: { sealed: "abc" } });
    expect(await host.next()).toEqual({ type: "pair", from: controller.id, data: { sealed: "abc" } });

    host.send({ type: "pair-reply", to: controller.id, data: { sealed: "def" } });
    expect(await controller.next()).toEqual({ type: "pair-reply", from: host.id, data: { sealed: "def" } });
  });

  it("reports unknown, closed and abandoned tags", async () => {
    await start();
    const host = await Device.online();
    const controller = await Device.online();

    controller.send({ type: "pair", tag, data: {} });
    expect(await controller.next()).toEqual({ type: "error", code: "no-such-pairing" });

    host.send({ type: "pair-open", tag });
    host.send({ type: "pair-close" });
    host.send({ type: "ice" });
    await host.next();
    controller.send({ type: "pair", tag, data: {} });
    expect(await controller.next()).toEqual({ type: "error", code: "no-such-pairing" });

    host.send({ type: "pair-open", tag });
    host.send({ type: "ice" });
    await host.next();
    host.socket.close();
    await host.closed;
    controller.send({ type: "pair", tag, data: {} });
    expect(await controller.next()).toEqual({ type: "error", code: "no-such-pairing" });
  });

  it("keeps only a device's latest tag", async () => {
    await start();
    const host = await Device.online();
    const controller = await Device.online();
    host.send({ type: "pair-open", tag });
    host.send({ type: "pair-open", tag: "ffffffffffffffff" });
    host.send({ type: "ice" });
    await host.next();

    controller.send({ type: "pair", tag, data: {} });
    expect(await controller.next()).toEqual({ type: "error", code: "no-such-pairing" });
    controller.send({ type: "pair", tag: "ffffffffffffffff", data: { n: 1 } });
    expect(await host.next()).toMatchObject({ type: "pair", data: { n: 1 } });
  });

  it.each(["short", "0123456789ABCDEF", 5])("rejects malformed tag %j", async (bad) => {
    await start();
    const device = await Device.online();
    device.send({ type: "pair-open", tag: bad });
    expect(await device.next()).toEqual({ type: "error", code: "bad-message" });
  });
});

describe("ice servers", () => {
  it("returns nothing when none are configured", async () => {
    await start();
    const device = await Device.online();
    device.send({ type: "ice" });
    expect(await device.next()).toEqual({ type: "ice", servers: [] });
  });

  it("returns STUN plus TURN credentials coturn will accept", async () => {
    const nowMs = 1_800_000_000_000;
    const turn = { secret: "turn-secret", urls: ["turn:turn.example.com:3478?transport=udp"], ttlSeconds: 3600 };
    await start({ stunUrls: ["stun:turn.example.com:3478"], turn, now: () => nowMs });
    const device = await Device.online();
    device.send({ type: "ice" });

    const username = `${nowMs / 1000 + 3600}:${device.id}`;
    expect(await device.next()).toEqual({
      type: "ice",
      servers: [
        { urls: ["stun:turn.example.com:3478"] },
        {
          urls: turn.urls,
          username,
          // coturn's use-auth-secret scheme: base64(HMAC-SHA1(secret, username))
          credential: createHmac("sha1", "turn-secret").update(username).digest("base64"),
        },
      ],
    });
  });

  it("issues credentials that expire", () => {
    const first = turnCredentials({ secret: "s", urls: ["turn:x"], ttlSeconds: 60 }, "abc", 1_000_000);
    expect(first.username).toBe("1060:abc");
    const later = turnCredentials({ secret: "s", urls: ["turn:x"], ttlSeconds: 60 }, "abc", 2_000_000);
    expect(later.credential).not.toBe(first.credential);
  });
});
