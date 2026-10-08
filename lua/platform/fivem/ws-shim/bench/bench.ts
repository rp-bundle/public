/**
 * Frames per second through the shim (D2), to check the claim that the
 * Lua/JS boundary is noise next to the portal's own traffic (tens of frames
 * a second per server).
 *
 * Lua (`ws.lua` in a real Lua 5.4) sends frames through the bundled shim to
 * a local echo server, and the echoes come back through the shim to Lua,
 * with every crossing through msgpack as on FiveM (`test/boundary.ts`). So
 * each frame crosses the boundary twice and the socket twice. It runs in
 * plain Node, not FXServer, and wasmoon's Lua is slower than FiveM's native
 * one, so the number is a floor for the shape, not a measurement of a stock
 * server; that one is taken on a real server (layer 5, `docs/testing.md`).
 *
 *   npm run bench            # 20 000 frames of 512 bytes
 *   FRAMES=100000 BYTES=4096 npm run bench
 */

import { WebSocketServer } from "ws";

import { boundary } from "../test/boundary.ts";

const frames = Number(process.env.FRAMES ?? 20_000);
const bytes = Number(process.env.BYTES ?? 512);

const echo = new WebSocketServer({ host: "127.0.0.1", port: 0 });
await new Promise<void>((ready) => echo.once("listening", ready));
echo.on("connection", (socket) => socket.on("message", (data, binary) => socket.send(data, { binary })));
const address = echo.address();
if (typeof address !== "object" || address === null) {
  throw new Error("the echo server has no port");
}

const b = await boundary();
await b.run(`
  received = 0
  handlers = {
    open = function() opened = true end,
    message = function() received = received + 1 end,
    close = function(reason) closed = reason end,
  }
  transport.connect("ws://127.0.0.1:${address.port}/ws", handlers)
`);
while (!(await b.run<boolean>("return opened == true"))) {
  await new Promise((wake) => setTimeout(wake, 5));
}

const frame = JSON.stringify({ type: "state_changed", padding: "x".repeat(Math.max(0, bytes - 40)) });
await b.run(`frame = ${JSON.stringify(frame)}`);
const batch = 500;
const start = process.hrtime.bigint();
for (let sent = 0; sent < frames; sent += batch) {
  await b.run(`for _ = 1, ${Math.min(batch, frames - sent)} do assert(transport.send(frame)) end`);
  // Lets the socket and the echoes run, as FiveM's ticks do.
  await new Promise((wake) => setImmediate(wake));
}
while ((await b.run<number>("return received")) < frames) {
  await new Promise((wake) => setImmediate(wake));
}
const seconds = Number(process.hrtime.bigint() - start) / 1e9;

console.log(
  `${frames} frames of ${frame.length} bytes, Lua → shim → echo → shim → Lua, in ${seconds.toFixed(2)} s: ` +
    `${Math.round(frames / seconds)} round trips/s, ${((seconds / frames) * 1e6).toFixed(1)} µs each`,
);

await b.run("transport.disconnect()");
while (!(await b.run<boolean>("return closed ~= nil"))) {
  await new Promise((wake) => setTimeout(wake, 5));
}
b.close();
for (const socket of echo.clients) {
  socket.terminate();
}
echo.close();
