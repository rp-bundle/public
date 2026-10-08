/**
 * The shim against a real local websocket server: connect, send, receive,
 * close codes and reconnects, and the contract's promises about ids and
 * `close`.
 */

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { after, before, describe, it } from "node:test";

import { ABNORMAL, SocketHub } from "../src/hub.ts";
import { Portal, Recorder } from "./support.ts";

let portal: Portal;

before(async () => {
  portal = await Portal.start();
});

after(async () => {
  await portal.stop();
});

/**
 * Opens a connection to the test portal and waits for it to open.
 * @returns the hub, its recorder and the connection's id.
 */
async function opened(): Promise<{ hub: SocketHub; recorder: Recorder; id: number }> {
  const recorder = new Recorder();
  const hub = new SocketHub(recorder.emit);
  const id = hub.connect(portal.url);
  await recorder.until("open", (events) => events.some((e) => e.name === "rpf-ws:open" && e.args[0] === id));
  return { hub, recorder, id };
}

describe("the socket hub", () => {
  it("opens, sends text both ways verbatim, and closes once", async () => {
    const { hub, recorder, id } = await opened();
    const before = portal.received.length;
    // Not JSON, and not valid as one: the shim moves text, it never parses.
    const frames = ['{"type":"hello"}', "not json {", "ünïcödé ✓", ""];
    for (const frame of frames) {
      assert.equal(hub.send(id, frame), true);
    }
    const server = portal.sockets.at(-1)!;
    await waitFor(() => portal.received.length === before + frames.length);
    assert.deepEqual(portal.received.slice(before), frames);

    server.send('{"type":"welcome"}');
    server.send("€ raw");
    await recorder.until("two messages", (events) => events.filter((e) => e.name === "rpf-ws:message").length === 2);
    assert.deepEqual(
      recorder.of(id).filter((e) => e.name === "rpf-ws:message").map((e) => e.args[1]),
      ['{"type":"welcome"}', "€ raw"],
    );

    hub.close(id);
    await recorder.until("close", (events) => events.some((e) => e.name === "rpf-ws:close"));
    assert.equal(hub.send(id, "late"), false, "a closed connection refuses sends");
    hub.close(id);
    await settle();
    assert.equal(recorder.events.filter((e) => e.name === "rpf-ws:close").length, 1, "close is emitted once");
    assert.equal(hub.size, 0);
  });

  it("reports the portal's close code and reason", async () => {
    const { recorder, id } = await opened();
    portal.sockets.at(-1)!.close(4001, "restarting");
    await recorder.until("close", (events) => events.some((e) => e.name === "rpf-ws:close"));
    assert.deepEqual(recorder.of(id).at(-1), { name: "rpf-ws:close", args: [id, 4001, "restarting"] });
  });

  it("reports a dropped connection as 1006", async () => {
    const { recorder, id } = await opened();
    portal.sockets.at(-1)!.terminate();
    await recorder.until("close", (events) => events.some((e) => e.name === "rpf-ws:close"));
    const close = recorder.of(id).at(-1)!;
    assert.equal(close.name, "rpf-ws:close");
    assert.equal(close.args[1], ABNORMAL);
  });

  it("closes once, and never opens, when nothing listens", async () => {
    const recorder = new Recorder();
    const hub = new SocketHub(recorder.emit);
    const closed = await freePort();
    const id = hub.connect(`ws://127.0.0.1:${closed}/ws`);
    await recorder.until("close", (events) => events.length > 0);
    await settle();
    assert.equal(recorder.events.length, 1);
    const close = recorder.events[0]!;
    assert.equal(close.name, "rpf-ws:close");
    assert.equal(close.args[0], id);
    assert.equal(close.args[1], ABNORMAL);
    assert.match(String(close.args[2]), /ECONNREFUSED/);
  });

  it("closes a malformed url after connect returns, never synchronously", async () => {
    const recorder = new Recorder();
    const hub = new SocketHub(recorder.emit);
    const id = hub.connect("not a url");
    assert.equal(recorder.events.length, 0, "nothing is emitted before the id is returned");
    await recorder.until("close", (events) => events.length === 1);
    assert.deepEqual(recorder.events[0]!.name, "rpf-ws:close");
    assert.equal(recorder.events[0]!.args[0], id);
    assert.equal(recorder.events[0]!.args[1], ABNORMAL);
  });

  it("abandons a handshake that never completes", async () => {
    // Accepts TCP and says nothing, like a portal that hung.
    const accepted: Socket[] = [];
    const silent = createServer((socket) => accepted.push(socket));
    await new Promise<void>((ready) => silent.listen(0, "127.0.0.1", ready));
    try {
      const recorder = new Recorder();
      const hub = new SocketHub(recorder.emit, { handshakeTimeoutMs: 100 });
      const id = hub.connect(`ws://127.0.0.1:${port(silent)}/ws`);
      await recorder.until("close", (events) => events.length === 1);
      assert.equal(recorder.events[0]!.name, "rpf-ws:close");
      assert.equal(recorder.events[0]!.args[0], id);

      // And one abandoned by the game server while it opens.
      const second = hub.connect(`ws://127.0.0.1:${port(silent)}/ws`);
      assert.equal(hub.send(second, "early"), false, "an opening connection refuses sends");
      hub.close(second);
      await recorder.until("second close", (events) => events.length === 2);
      assert.equal(recorder.events[1]!.args[0], second);
      await settle();
      assert.equal(recorder.of(second).filter((e) => e.name === "rpf-ws:open").length, 0);
    } finally {
      for (const socket of accepted) {
        socket.destroy();
      }
      await new Promise<void>((done) => silent.close(() => done()));
    }
  });

  it("refuses a binary frame by closing", async () => {
    const { recorder, id } = await opened();
    portal.sockets.at(-1)!.send(Buffer.from([1, 2, 3]), { binary: true });
    await recorder.until("close", (events) => events.some((e) => e.name === "rpf-ws:close"));
    assert.equal(recorder.of(id).filter((e) => e.name === "rpf-ws:message").length, 0);
    assert.equal(recorder.of(id).at(-1)!.args[1], 1003);
  });

  it("reconnects under a new id, and the old id stays dead", async () => {
    const { hub, recorder, id } = await opened();
    portal.sockets.at(-1)!.terminate();
    await recorder.until("close", (events) => events.some((e) => e.name === "rpf-ws:close"));
    const again = hub.connect(portal.url);
    assert.notEqual(again, id);
    await recorder.until("reopen", (events) => events.some((e) => e.name === "rpf-ws:open" && e.args[0] === again));
    assert.equal(hub.send(id, "old"), false);
    assert.equal(hub.send(again, "new"), true);
    await waitFor(() => portal.received.at(-1) === "new");
    hub.close(again);
    await recorder.until("close", (events) => events.filter((e) => e.name === "rpf-ws:close").length === 2);
  });

  it("refuses sends that are not strings, and unknown ids", () => {
    const hub = new SocketHub(() => {});
    assert.equal(hub.send(99, "x"), false);
    assert.equal(hub.send(99, 42 as unknown as string), false);
    hub.close(99);
  });

  it("mints random hex of exactly the length asked for", () => {
    const hub = new SocketHub(() => {});
    for (const n of [1, 2, 7, 32, 1024]) {
      const hex = hub.random_hex(n);
      assert.equal(hex.length, n);
      assert.match(hex, /^[0-9a-f]+$/);
    }
    assert.notEqual(hub.random_hex(32), hub.random_hex(32));
    for (const n of [0, -1, 1.5, 1025, Number.NaN]) {
      assert.throws(() => hub.random_hex(n), RangeError);
    }
  });

  it("never parses a frame", () => {
    for (const file of readdirSync(new URL("../src/", import.meta.url))) {
      const source = readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");
      assert.doesNotMatch(source, /JSON\.(parse|stringify)/, `${file} touches JSON`);
    }
  });
});

/**
 * Waits for a condition to hold.
 * @param done The condition.
 */
async function waitFor(done: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!done()) {
    if (Date.now() > deadline) {
      throw new Error("timed out");
    }
    await new Promise((wake) => setTimeout(wake, 5));
  }
}

/** Lets anything already queued run, so a test can say nothing more came. */
async function settle(): Promise<void> {
  await new Promise((wake) => setTimeout(wake, 50));
}

/**
 * The port a listening server took.
 * @param server The server.
 * @returns port Its port.
 */
function port(server: Server): number {
  const address = server.address();
  assert(address !== null && typeof address === "object");
  return address.port;
}

/**
 * A port nothing is listening on.
 * @returns port The port.
 */
async function freePort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((ready) => probe.listen(0, "127.0.0.1", ready));
  const free = port(probe);
  await new Promise<void>((done) => probe.close(() => done()));
  return free;
}
