/**
 * The Lua/JS contract (D2), both ways.
 *
 * - **The two copies agree.** `src/contract.ts` (checked by `tsc --strict`)
 *   and `../transport.lua` (checked by lua-language-server) name the same
 *   operations and events with the same parameters and types, so a change
 *   to one that is not made to the other fails here.
 * - **The real shim and the real transport work across the boundary**: the
 *   bundled shim and the adapter's `ws.lua` in a real Lua 5.4, every value
 *   through msgpack (`boundary.ts`), against a real local websocket server.
 *   All four operations, including a close while frames are being sent.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:net";
import { after, before, describe, it } from "node:test";

import { EVENTS } from "../src/contract.ts";
import { type Boundary, boundary } from "./boundary.ts";
import { Portal } from "./support.ts";

/** One operation or event: its name, and each parameter's name and type. */
interface Signature {
  name: string;
  params: [string, string][];
  returns: string;
}

/** The Lua types the TypeScript ones are written as. */
const LUA_TYPE: Record<string, string> = { number: "integer", string: "string", boolean: "boolean", void: "" };

/**
 * The operations and events `contract.ts` declares.
 * @returns operations and events, by name.
 */
function typescript(): { operations: Signature[]; events: Signature[] } {
  const source = readFileSync(new URL("../src/contract.ts", import.meta.url), "utf8");
  const body = (name: string) => {
    const start = source.indexOf(`export interface ${name} {`);
    return source.slice(start, source.indexOf("\n}\n", start));
  };
  const parse = (text: string, pattern: RegExp): Signature[] =>
    [...text.matchAll(pattern)].map((match) => ({
      name: match[1]!,
      params: match[2]!
        .split(",")
        .filter((param) => param.trim() !== "")
        .map((param) => {
          const [name, type] = param.split(":").map((part) => part.trim());
          return [name!, LUA_TYPE[type!] ?? type!];
        }),
      returns: LUA_TYPE[match[3]!] ?? match[3]!,
    }));
  return {
    operations: parse(body("WsShim"), /^ {2}(\w+)\(([^)]*)\): (\w+);$/gm),
    events: parse(body("WsEvents"), /^ {2}"([\w:-]+)"\(([^)]*)\): (\w+);$/gm),
  };
}

/**
 * The operations and events `transport.lua` declares, from its functions
 * and their `---@param` and `---@return` lines.
 * @returns operations and events, by name.
 */
function lua(): { operations: Signature[]; events: Signature[] } {
  const source = readFileSync(new URL("../../transport.lua", import.meta.url), "utf8");
  const blocks = source.split(/\n\n/);
  const operations: Signature[] = [];
  const events: Signature[] = [];
  for (const block of blocks) {
    const params = [...block.matchAll(/^---@param (\w+) (\w+)/gm)].map((m): [string, string] => [m[1]!, m[2]!]);
    const returned = /^---@return (\w+)/m.exec(block)?.[1] ?? "";
    const operation = /^function WsShim:(\w+)\(([^)]*)\) end$/m.exec(block);
    const event = /^WsEvents\["([\w:-]+)"\] = function\(([^)]*)\) end$/m.exec(block);
    const declared = (operation ?? event)?.[2]?.split(",").map((p) => p.trim()).filter((p) => p !== "");
    if (operation) {
      assert.deepEqual(params.map(([name]) => name), declared, `${operation[1]}'s @params match its parameters`);
      operations.push({ name: operation[1]!, params, returns: returned });
    } else if (event) {
      assert.deepEqual(params.map(([name]) => name), declared, `${event[1]}'s @params match its parameters`);
      events.push({ name: event[1]!, params, returns: "" });
    }
  }
  return { operations, events };
}

describe("the two copies of the contract", () => {
  it("name the same operations, with the same parameters and types", () => {
    const ts = typescript();
    assert.ok(ts.operations.length >= 4, "found the TypeScript operations");
    assert.deepEqual(lua().operations, ts.operations);
  });

  it("name the same events, with the same parameters and types", () => {
    const ts = typescript();
    assert.deepEqual(ts.events.map((event) => event.name), [...EVENTS]);
    assert.deepEqual(lua().events, ts.events);
  });
});

describe("the shim, from Lua, across the boundary", () => {
  let portal: Portal;
  let b: Boundary;

  before(async () => {
    portal = await Portal.start();
    b = await boundary();
  });

  after(async () => {
    b.close();
    await portal.stop();
  });

  /**
   * Waits until Lua has seen something.
   * @param what For the timeout's message.
   * @param done The condition.
   */
  async function until(what: string, done: () => boolean): Promise<void> {
    const deadline = Date.now() + 5_000;
    while (!done()) {
      if (Date.now() > deadline) {
        throw new Error(`timed out waiting for ${what}; Lua saw ${JSON.stringify(b.seen)}`);
      }
      await new Promise((wake) => setTimeout(wake, 5));
    }
  }

  /** How many closes Lua has seen. */
  const closes = () => b.seen.filter((s) => s.kind === "close").length;

  it("connects, sends, receives and closes", async () => {
    await b.run(`transport.connect(${JSON.stringify(portal.url)}, handlers)`);
    await until("open", () => b.seen.some((s) => s.kind === "open"));

    const frames = ['{"type":"hello","x":[]}', "ünïcödé ✓ {not json"];
    for (const frame of frames) {
      assert.equal(await b.run<boolean>(`return transport.send(${JSON.stringify(frame)})`), true);
    }
    await until("the portal received both", () => portal.received.length >= 2);
    assert.deepEqual(portal.received.slice(-2), frames);

    const server = portal.sockets.at(-1)!;
    server.send('{"type":"welcome","note":"€"}');
    await until("a message", () => b.seen.some((s) => s.kind === "message"));
    assert.deepEqual(b.seen.at(-1), { kind: "message", value: '{"type":"welcome","note":"€"}' });

    server.close(4001, "restarting");
    await until("close", () => closes() === 1);
    assert.deepEqual(b.seen.at(-1), { kind: "close", value: "closed (4001): restarting" });
    assert.equal(await b.run<boolean>(`return transport.send("late")`), false);
  });

  it("mints random hex through the shim", async () => {
    const hex = await b.run<string>(`return exports["rpf-ws"]:random_hex(32)`);
    assert.match(hex, /^[0-9a-f]{32}$/);
  });

  it("survives a close during a burst of sends, and closes once", async () => {
    b.seen.length = 0;
    await b.run(`transport.connect(${JSON.stringify(portal.url)}, handlers)`);
    await until("open", () => b.seen.some((s) => s.kind === "open"));
    const server = portal.sockets.at(-1)!;
    // The portal drops the connection as soon as the burst starts.
    server.once("message", () => server.terminate());
    let refused = false;
    for (let round = 0; round < 200 && !refused; round += 1) {
      const sent = await b.run<boolean>(`
        local ok = true
        for i = 1, 50 do ok = transport.send(("frame %d"):format(i)) and ok end
        return ok
      `);
      refused = !sent;
      await new Promise((wake) => setTimeout(wake, 1));
    }
    assert.ok(refused, "sends are refused once the close is through");
    await until("close", () => closes() === 1);
    await new Promise((wake) => setTimeout(wake, 50));
    assert.equal(closes(), 1, "one close, however many sends were in flight");
    assert.equal(b.seen.at(-1)!.kind, "close");
  });

  it("closes once when the game server gives up mid-send, and reconnects", async () => {
    b.seen.length = 0;
    await b.run(`transport.connect(${JSON.stringify(portal.url)}, handlers)`);
    await until("open", () => b.seen.some((s) => s.kind === "open"));
    const sent = await b.run<boolean[]>(`
      local a = transport.send("before")
      transport.disconnect()
      local b = transport.send("after")
      return { a, b }
    `);
    assert.deepEqual(Object.values(sent), [true, false]);
    await until("close", () => closes() === 1);
    assert.match(b.seen.at(-1)!.value, /^closed \(1000\)/);

    await b.run(`transport.connect(${JSON.stringify(portal.url)}, handlers)`);
    await until("reopen", () => b.seen.filter((s) => s.kind === "open").length === 2);
    assert.equal(await b.run<boolean>(`return transport.send("again")`), true);
    await until("the portal received it", () => portal.received.at(-1) === "again");
    await b.run(`transport.disconnect()`);
    await until("second close", () => closes() === 2);
  });

  it("closes once, and never opens, when nothing listens", async () => {
    b.seen.length = 0;
    const probe = createServer();
    await new Promise<void>((ready) => probe.listen(0, "127.0.0.1", ready));
    const address = probe.address();
    assert(address !== null && typeof address === "object");
    await new Promise<void>((done) => probe.close(() => done()));
    await b.run(`transport.connect("ws://127.0.0.1:${address.port}/ws", handlers)`);
    await until("close", () => closes() === 1);
    await new Promise((wake) => setTimeout(wake, 50));
    assert.deepEqual(
      b.seen.map((s) => s.kind),
      ["close"],
    );
    assert.match(b.seen[0]!.value, /^closed \(1006\)/);
  });
});
