/**
 * The contract between the FiveM adapter's Lua and this shim (D2).
 *
 * FiveM's Lua runtime has no websocket client, so this resource, running in
 * FiveM's built-in JS runtime, owns the portal socket. Everything crosses
 * the Lua/JS boundary through FiveM's exports and events, which serialise
 * every argument with msgpack. Frames cross it as **JSON strings, never as
 * tables**: the shim never parses a frame, it moves text, so the marshalling
 * surface is one string per frame and `rpf.json` stays the only codec.
 *
 * The contract is written down twice, and both copies are checked:
 * `lua/platform/fivem/transport.lua` (a `---@meta` class, checked by
 * lua-language-server) and this file (checked by `tsc --strict`).
 * `test/contract.test.ts` fails when the two disagree on a name or a
 * parameter, and drives the real shim from the real Lua transport across an
 * emulated boundary.
 *
 * The operations are the server platform's transport (`connect`, `disconnect`
 * as `close`, `send`), with a connection id, plus `random_hex`, because the
 * JS runtime has the only cryptographic randomness a FiveM server offers Lua.
 */

/** The resource this shim runs as, which the Lua adapter calls through `exports`. */
export const RESOURCE = "rpf-ws";

/**
 * What the shim exports, called from Lua as `exports["rpf-ws"]:<name>(...)`.
 *
 * Every argument and result is a string, a number or a boolean, never a
 * table, so msgpack has nothing to get wrong.
 */
export interface WsShim {
  /**
   * Opens a websocket. Returns at once with the connection's id; the outcome
   * arrives as events naming that id: `open` then any number of `message`,
   * and exactly one `close`, or a `close` alone if it never opened.
   * @param url The portal's `ws://` or `wss://` url.
   * @returns id A new id, never reused while this resource runs.
   */
  connect(url: string): number;

  /**
   * Sends one text frame on an open connection.
   * @param id The connection, from `connect`.
   * @param text The frame, already encoded by `rpf.json`. Never parsed here.
   * @returns sent False when that connection is not open (still opening,
   * closing, closed or unknown); the core keeps the frame in its outbox.
   */
  send(id: number, text: string): boolean;

  /**
   * Closes a connection, or abandons it while it opens. Its `close` event
   * still arrives, once. Does nothing for an id that is closed or unknown.
   * @param id The connection, from `connect`.
   */
  close(id: number): void;

  /**
   * Random lowercase hex digits from Node's cryptographic generator, which
   * the core mints envelope and instance ids from.
   * @param n How many digits, from 1 to 1024.
   * @returns hex Exactly `n` characters from `0-9a-f`.
   */
  random_hex(n: number): string;
}

/**
 * The events the shim emits to the Lua adapter, as server-local events
 * (`TriggerEvent`), never network events, so no client can forge one.
 * Each names the connection, so an event from a connection the adapter has
 * given up on is recognised and ignored.
 */
export interface WsEvents {
  /**
   * The connection is open and `send` works.
   * @param id The connection.
   */
  "rpf-ws:open"(id: number): void;

  /**
   * One text frame arrived, verbatim.
   * @param id The connection.
   * @param text The frame, as the portal sent it.
   */
  "rpf-ws:message"(id: number, text: string): void;

  /**
   * The connection ended, or never opened. Exactly once per `connect`, and
   * nothing for that id follows it.
   * @param id The connection.
   * @param code The websocket close code, 1006 when the socket failed or
   * never opened.
   * @param reason The peer's close reason, or a description of the failure.
   */
  "rpf-ws:close"(id: number, code: number, reason: string): void;
}

/** The event names, in the order the contract lists them. */
export const EVENTS = ["rpf-ws:open", "rpf-ws:message", "rpf-ws:close"] as const satisfies readonly (keyof WsEvents)[];

/** The most digits `random_hex` hands out in one call. */
export const MAX_RANDOM_HEX = 1024;
