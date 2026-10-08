/**
 * The shim's sockets, apart from FiveM: everything `main.ts` exports, behind
 * an `emit` function, so the unit tests run it in plain Node against a real
 * local websocket server.
 */

// Not `node:crypto`: the prefix is newer than some FXServer builds' Node.
import { randomBytes } from "crypto";
import WebSocket from "ws";

import { MAX_RANDOM_HEX, type WsEvents, type WsShim } from "./contract.ts";

/** Delivers one contract event to the Lua adapter. */
export type Emit = <K extends keyof WsEvents>(name: K, ...args: Parameters<WsEvents[K]>) => void;

/** Timings, which the tests shrink. */
export interface HubOptions {
  /**
   * How long an opening handshake may take before the attempt is abandoned
   * and closed. Without it a portal that accepts the TCP connection and
   * never answers would leave the core waiting for a `close` for ever.
   */
  handshakeTimeoutMs?: number;
}

/** The production timings. */
export const DEFAULTS: Required<HubOptions> = {
  handshakeTimeoutMs: 30_000,
};

/** The close code reported for a socket that failed or never opened. */
export const ABNORMAL = 1006;

/**
 * Every socket the adapter has opened and not yet heard close, by id.
 *
 * It keeps the contract's promises, so the Lua side can rely on them rather
 * than defend against them: ids are never reused, `close` is emitted exactly
 * once per `connect` and nothing follows it, and frames are moved as text,
 * never parsed.
 */
export class SocketHub implements WsShim {
  readonly #emit: Emit;
  readonly #options: Required<HubOptions>;
  readonly #sockets = new Map<number, WebSocket>();
  #next = 0;

  /**
   * @param emit Where events go: FiveM's `emit` in `main.ts`, a recorder in
   * the tests.
   * @param options Timing overrides.
   */
  constructor(emit: Emit, options: HubOptions = {}) {
    this.#emit = emit;
    this.#options = { ...DEFAULTS, ...options };
  }

  /** How many connections are open or opening, for the tests. */
  get size(): number {
    return this.#sockets.size;
  }

  connect(url: string): number {
    this.#next += 1;
    const id = this.#next;
    let socket: WebSocket;
    try {
      if (typeof url !== "string") {
        throw new TypeError("the url is not a string");
      }
      socket = new WebSocket(url, {
        handshakeTimeout: this.#options.handshakeTimeoutMs,
        // The portal does not negotiate compression, and offering it would
        // only cost CPU on every frame if one ever did.
        perMessageDeflate: false,
      });
    } catch (error) {
      // A malformed url throws before any socket exists. The contract still
      // owes one `close`, after `connect` has returned the id it names.
      const reason = `cannot connect: ${describe(error)}`;
      setImmediate(() => this.#emit("rpf-ws:close", id, ABNORMAL, reason));
      return id;
    }
    this.#sockets.set(id, socket);
    // ws reports a failure as `error` and then `close`; the error says why,
    // which a 1006 close does not.
    let failure = "";
    socket.on("error", (error) => {
      failure = describe(error);
    });
    socket.on("open", () => this.#emit("rpf-ws:open", id));
    socket.on("message", (data, isBinary) => {
      if (isBinary) {
        // The protocol is text frames only, and the core's codec is the
        // only thing that reads one, so a binary frame is refused rather
        // than guessed at.
        socket.close(1003, "binary frames are not part of the protocol");
        return;
      }
      this.#emit("rpf-ws:message", id, text(data));
    });
    socket.on("close", (code, reason) => {
      this.#sockets.delete(id);
      const said = reason.toString("utf8");
      this.#emit("rpf-ws:close", id, code, said !== "" ? said : failure);
    });
    return id;
  }

  send(id: number, text: string): boolean {
    const socket = this.#sockets.get(id);
    if (socket === undefined || socket.readyState !== WebSocket.OPEN || typeof text !== "string") {
      return false;
    }
    // A string goes out as a text frame. A write that fails later fails the
    // socket, which reports it as `close`.
    socket.send(text);
    return true;
  }

  close(id: number): void {
    const socket = this.#sockets.get(id);
    if (socket === undefined) {
      return;
    }
    if (socket.readyState === WebSocket.CONNECTING) {
      // Abandons the handshake; ws still emits `close`.
      socket.terminate();
    } else {
      socket.close(1000, "closed by the game server");
    }
  }

  random_hex(n: number): string {
    if (!Number.isInteger(n) || n < 1 || n > MAX_RANDOM_HEX) {
      throw new RangeError(`random_hex wants 1 to ${MAX_RANDOM_HEX} digits, not ${String(n)}`);
    }
    return randomBytes(Math.ceil(n / 2))
      .toString("hex")
      .slice(0, n);
  }
}

/**
 * A text frame's payload as a string. ws has already checked it is UTF-8,
 * and closes the socket (1007) when it is not.
 * @param data What ws handed over for one message.
 * @returns text The frame.
 */
function text(data: WebSocket.RawData): string {
  if (Array.isArray(data)) {
    return Buffer.concat(data).toString("utf8");
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8");
  }
  return data.toString("utf8");
}

/**
 * A thrown value as one line for a close reason.
 * @param error Whatever was thrown.
 * @returns line Its message.
 */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
