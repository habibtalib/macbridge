import { startSignalingServer } from "./server.ts";

const list = (value: string | undefined) =>
  (value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);

const env = process.env;

/** A positive whole number from the environment, or undefined to keep the default. */
const count = (name: string): number | undefined => {
  const value = env[name];
  if (value === undefined || value === "") return undefined;
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) {
    console.error(`${name} must be a whole number above 0.`);
    process.exit(1);
  }
  return number;
};
const port = Number(env.PORT ?? 8787);
const host = env.HOST ?? "0.0.0.0";
const accessToken = env.ACCESS_TOKEN || undefined;
const turnUrls = list(env.TURN_URLS);

if (!accessToken && env.ALLOW_NO_TOKEN !== "1") {
  console.error("ACCESS_TOKEN is not set. Set it, or set ALLOW_NO_TOKEN=1 for local testing.");
  process.exit(1);
}
if (accessToken && accessToken.length < 24) {
  console.error("ACCESS_TOKEN is too short; use at least 24 random characters (openssl rand -base64 32).");
  process.exit(1);
}
if (Boolean(env.TURN_SECRET) !== turnUrls.length > 0) {
  console.error("Set both TURN_SECRET and TURN_URLS, or neither.");
  process.exit(1);
}

const server = await startSignalingServer({
  port,
  host,
  accessToken,
  stunUrls: list(env.STUN_URLS),
  turn: env.TURN_SECRET ? { secret: env.TURN_SECRET, urls: turnUrls } : undefined,
  limits: {
    messagesPerSecond: count("RATE_LIMIT_PER_SECOND"),
    burst: count("RATE_LIMIT_BURST"),
    maxBufferedBytes: count("MAX_BUFFERED_BYTES"),
    maxConnections: count("MAX_CONNECTIONS"),
    maxConnectionsPerIp: count("MAX_CONNECTIONS_PER_IP"),
  },
  trustProxy: env.TRUST_PROXY === "1",
  log: (line) => console.log(new Date().toISOString(), line),
});
console.log(
  `macbridge signaling listening on ws://${host}:${server.port}` +
    ` (token ${accessToken ? "required" : "NOT required"}, TURN ${env.TURN_SECRET ? "on" : "off"})`,
);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void server.close().then(() => process.exit(0));
  });
}
