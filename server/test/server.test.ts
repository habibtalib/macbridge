import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket } from "ws";
import { CLOSE, startSignalingServer, type SignalingServer } from "../src/server.ts";

let server: SignalingServer;
const sockets: WebSocket[] = [];

beforeEach(async () => {
  server = await startSignalingServer({ port: 0, host: "127.0.0.1" });
});

afterEach(async () => {
  for (const socket of sockets.splice(0)) socket.terminate();
  await server.close();
});

/** A test client that queues incoming messages so none are missed. */
class Device {
  private queue: unknown[] = [];
  private waiters: ((message: unknown) => void)[] = [];
  readonly closed: Promise<number>;
  readonly socket: WebSocket;

  private constructor(socket: WebSocket) {
    this.socket = socket;
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const waiter = this.waiters.shift();
      if (waiter) waiter(message);
      else this.queue.push(message);
    });
    this.closed = new Promise((resolve) => socket.on("close", (code) => resolve(code)));
  }

  static async open(): Promise<Device> {
    const socket = new WebSocket(`ws://127.0.0.1:${server.port}`);
    sockets.push(socket);
    const device = new Device(socket);
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", reject);
    });
    return device;
  }

  static async online(id: string): Promise<Device> {
    const device = await Device.open();
    device.send({ type: "hello", id });
    expect(await device.next()).toEqual({ type: "welcome" });
    return device;
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

describe("signaling server", () => {
  it("forwards signals between two devices, tagging the sender", async () => {
    const studio = await Device.online("studio");
    const laptop = await Device.online("laptop");

    laptop.send({ type: "signal", to: "studio", data: { kind: "request" } });
    expect(await studio.next()).toEqual({ type: "signal", from: "laptop", data: { kind: "request" } });

    studio.send({ type: "signal", to: "laptop", data: { kind: "offer", sdp: "v=0" } });
    expect(await laptop.next()).toEqual({
      type: "signal",
      from: "studio",
      data: { kind: "offer", sdp: "v=0" },
    });
  });

  it("ignores a `from` field supplied by the client", async () => {
    const studio = await Device.online("studio");
    const laptop = await Device.online("laptop");

    laptop.send({ type: "signal", to: "studio", from: "someone-else", data: { kind: "bye" } });
    expect(await studio.next()).toMatchObject({ from: "laptop" });
  });

  it("tells the sender when the target is offline", async () => {
    const laptop = await Device.online("laptop");
    laptop.send({ type: "signal", to: "studio", data: { kind: "request" } });
    expect(await laptop.next()).toEqual({ type: "error", code: "offline", to: "studio" });
  });

  it("stops forwarding to a device once it disconnects", async () => {
    const studio = await Device.online("studio");
    const laptop = await Device.online("laptop");
    studio.socket.close();
    await studio.closed;

    laptop.send({ type: "signal", to: "studio", data: { kind: "request" } });
    expect(await laptop.next()).toEqual({ type: "error", code: "offline", to: "studio" });
  });

  it("rejects a signal sent before hello", async () => {
    const device = await Device.open();
    device.send({ type: "signal", to: "studio", data: {} });
    expect(await device.next()).toEqual({ type: "error", code: "bad-message" });
    expect(await device.closed).toBe(CLOSE.protocol);
  });

  it.each(["", "has space", "a".repeat(65), "../etc", 42, null])("rejects device id %j", async (id) => {
    const device = await Device.open();
    device.send({ type: "hello", id });
    expect(await device.next()).toEqual({ type: "error", code: "bad-id" });
    expect(await device.closed).toBe(CLOSE.protocol);
  });

  it.each(["not json", "[]", '"text"', '{"type":"signal","to":"x"}', '{"type":"signal","to":1,"data":{}}'])(
    "rejects malformed message %s",
    async (raw) => {
      const device = await Device.online("laptop");
      device.send(raw);
      expect(await device.next()).toEqual({ type: "error", code: "bad-message" });
      expect(await device.closed).toBe(CLOSE.protocol);
    },
  );

  it("lets a reconnecting device replace its old connection", async () => {
    const first = await Device.online("studio");
    const second = await Device.online("studio");
    expect(await first.closed).toBe(CLOSE.replaced);

    const laptop = await Device.online("laptop");
    laptop.send({ type: "signal", to: "studio", data: { kind: "request" } });
    expect(await second.next()).toMatchObject({ from: "laptop" });
  });

  it("closes connections that send oversized messages", async () => {
    const device = await Device.online("laptop");
    device.send({ type: "signal", to: "studio", data: { blob: "x".repeat(70 * 1024) } });
    expect(await device.closed).toBe(1009);
  });
});
