/**
 * The Lua/JS boundary as FiveM draws it, for the contract test: the bundled
 * shim runs in a context of its own with FiveM's `exports` and `emit`, the
 * adapter's real `ws.lua` runs in a real Lua 5.4 (wasmoon), and every value
 * that crosses goes through a msgpack round trip, as FiveM serialises
 * exports and events.
 *
 * It is an emulation: FiveM's own marshalling is checked on a real server
 * (layer 5, `docs/testing.md`). What it proves is that the two copies of the
 * contract are wired to each other, that only strings, numbers and booleans
 * cross, and that the transport keeps its promises through the shim.
 */

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

import { decode, encode } from "@msgpack/msgpack";
import { type LuaEngine, LuaFactory } from "wasmoon";

/** One value through msgpack and back, as every argument crossing FiveM's boundary is. */
export function crossing<T>(values: T): T {
  return decode(encode(values)) as T;
}

/** The pieces of the FiveM adapter the test runs. */
const ADAPTER = new URL("../../", import.meta.url);

/** What a handler of the transport saw, from Lua. */
export interface Seen {
  kind: "open" | "message" | "close";
  value: string;
}

/** A running emulation: the shim's exports, a Lua state with the transport, and what Lua saw. */
export interface Boundary {
  lua: LuaEngine;
  seen: Seen[];
  logs: string[];
  /** Runs Lua in the adapter's state and returns its first result. */
  run<T>(code: string): Promise<T>;
  close(): void;
}

/**
 * Builds the boundary: loads `dist/rpf-ws.js` as FiveM would, then the
 * adapter's `ws.lua` and the same three event handlers `server.lua` wires.
 * @returns boundary The running emulation.
 */
export async function boundary(): Promise<Boundary> {
  const exported = new Map<string, (...args: unknown[]) => unknown>();
  const handlers = new Map<string, (...args: unknown[]) => void>();
  const seen: Seen[] = [];
  const logs: string[] = [];

  // As FiveM runs a server script: Node's globals, with FiveM's `exports`
  // and `emit` beside them.
  const fivemExports = (name: string, fn: (...args: unknown[]) => unknown) => exported.set(name, fn);
  const fivemEmit = (name: string, ...args: unknown[]) => {
    const handler = handlers.get(name);
    if (handler) {
      handler(...crossing(args));
    }
  };
  const bundle = readFileSync(new URL("../dist/rpf-ws.js", import.meta.url), "utf8");
  const script = new Function("exports", "emit", "require", bundle) as (
    exports: typeof fivemExports,
    emit: typeof fivemEmit,
    require: NodeJS.Require,
  ) => void;
  script(fivemExports, fivemEmit, createRequire(new URL("../dist/rpf-ws.js", import.meta.url)));

  const lua = await new LuaFactory().createEngine();
  lua.global.set("__export", (resource: string, name: string, ...args: unknown[]) => {
    const fn = exported.get(name);
    if (resource !== "rpf-ws" || !fn) {
      throw new Error(`no export ${resource}.${name}`);
    }
    return crossing([fn(...crossing(args))])[0];
  });
  lua.global.set("__handle", (name: string, fn: (...args: unknown[]) => void) => handlers.set(name, fn));
  lua.global.set("__after", (ms: number, fn: () => void) => setTimeout(() => fn(), ms));
  lua.global.set("__seen", (kind: Seen["kind"], value: string) => seen.push({ kind, value }));
  lua.global.set("__log", (line: string) => logs.push(line));

  await lua.doString(`
    exports = setmetatable({}, {
      __index = function(_, resource)
        return setmetatable({}, {
          __index = function(_, name)
            return function(_, ...)
              return __export(resource, name, ...)
            end
          end,
        })
      end,
    })
    function AddEventHandler(name, fn)
      __handle(name, fn)
    end
    rpf = { fivem = {} }
  `);
  await lua.doString(readFileSync(new URL("ws.lua", ADAPTER), "utf8"));
  // The transport, and server.lua's three handlers for the shim's events.
  await lua.doString(`
    local shim = exports["rpf-ws"]
    transport = rpf.fivem.ws.new(shim, __after, function(level, message) __log(level .. ": " .. message) end)
    handlers = {
      open = function() __seen("open", "") end,
      message = function(text) __seen("message", text) end,
      close = function(reason) __seen("close", reason) end,
    }
    AddEventHandler("rpf-ws:open", function(id) transport.opened(id) end)
    AddEventHandler("rpf-ws:message", function(id, text) transport.received(id, text) end)
    AddEventHandler("rpf-ws:close", function(id, code, reason) transport.closed(id, code, reason) end)
  `);

  return {
    lua,
    seen,
    logs,
    async run<T>(code: string): Promise<T> {
      return (await lua.doString(code)) as T;
    },
    close() {
      lua.global.close();
    },
  };
}
