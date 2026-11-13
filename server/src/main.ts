import { startSignalingServer } from "./server.ts";

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? "0.0.0.0";

const server = await startSignalingServer({
  port,
  host,
  log: (line) => console.log(new Date().toISOString(), line),
});
console.log(`macbridge signaling listening on ws://${host}:${server.port}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void server.close().then(() => process.exit(0));
  });
}
