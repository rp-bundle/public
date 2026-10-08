/**
 * The `rpf-ws` resource's entry point: the `SocketHub` behind FiveM's
 * exports and events. `npm run build` bundles this, `ws` included, into
 * `dist/rpf-ws.js`, the one file the resource's manifest loads, so a server
 * owner never runs `npm install`.
 */

import type { WsShim } from "./contract.ts";
import { type Emit, SocketHub } from "./hub.ts";

// ws calls back on Node's own thread, where FXServer does not allow natives,
// and `emit` is one. `setImmediate` is FXServer's way back to the main
// thread, and runs callbacks in the order they were queued, so the events
// keep theirs.
const deliver: Emit = (name, ...args) => {
  setImmediate(() => emit(name, ...args));
};
const hub: WsShim = new SocketHub(deliver);

exports("connect", (url: string) => hub.connect(url));
exports("send", (id: number, text: string) => hub.send(id, text));
exports("close", (id: number) => hub.close(id));
exports("random_hex", (n: number) => hub.random_hex(n));
