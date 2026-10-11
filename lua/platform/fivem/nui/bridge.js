// @ts-check
/**
 * How the page talks to `ui.lua` (NUI callbacks) and makes the client's HTTP
 * requests to the portal, apart from the screens so the shim's tests run it
 * with no page (`ws-shim/test/bridge.test.ts`).
 *
 * Neither may leave a player waiting without a word. A callback that fails,
 * stalls or answers with something that is not `{ ok }` is an answer of its
 * own, `UNANSWERED`, shown to the player and written to the page's console,
 * never an empty object that looks like nothing happened. An HTTP request
 * the page cannot hand back is `ui.lua`'s to settle: it answers every request
 * status 0 once `HTTP_TIMEOUT_MS` (in `ui.lua`) passes.
 */

/** How long a portal request may take, headers and body, before it counts as no answer. */
export const HTTP_TIMEOUT_MS = 30_000;

/** How long a NUI callback may take to answer. `ui.lua` answers each at once, so this is long. */
export const CALLBACK_TIMEOUT_MS = 10_000;

/** What the player is shown when a callback has no usable answer. */
export const UNANSWERED = "The game did not answer. Please try again.";

/**
 * A callback's answer. `unanswered` says `ui.lua`'s own answer never came, so
 * what was asked may still be under way.
 * @typedef {{ ok: true } | { ok: false, error: string, unanswered?: true }} Answer
 */

/**
 * What a bridge is built on: the page's own, or a test's.
 * @typedef {object} BridgeDeps
 * @property {string} resource The resource that names the callbacks.
 * @property {typeof fetch} [fetcher] How to fetch. The page's `fetch` by default.
 * @property {(message: string) => void} [report] Where a failure is written. The page's console by default.
 * @property {number} [callbackTimeoutMs] `CALLBACK_TIMEOUT_MS`, shorter in tests.
 * @property {number} [httpTimeoutMs] `HTTP_TIMEOUT_MS`, shorter in tests.
 */

/**
 * Something that can swap sealed passwords back into a body (`seal.js`).
 * @typedef {{ unseal: (body: string | null) => string | null }} Unsealer
 */

/** NUI callbacks and portal requests for one page. */
export class Bridge {
  /**
   * @param {BridgeDeps} deps What it is built on.
   */
  constructor(deps) {
    this.resource = deps.resource;
    this.fetcher = deps.fetcher ?? ((input, init) => fetch(input, init));
    this.report = deps.report ?? ((message) => console.error(message));
    this.callbackTimeoutMs = deps.callbackTimeoutMs ?? CALLBACK_TIMEOUT_MS;
    this.httpTimeoutMs = deps.httpTimeoutMs ?? HTTP_TIMEOUT_MS;
  }

  /**
   * Calls one of `ui.lua`'s NUI callbacks. Never rejects.
   * @param {string} name The callback.
   * @param {object} data What to send.
   * @param {{ quiet?: boolean }} [options] `quiet` leaves a failure out of the console, for a caller that retries and reports once itself.
   * @returns {Promise<Answer>} Its answer, or `UNANSWERED` if there was none.
   */
  async call(name, data, options = {}) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), this.callbackTimeoutMs);
    try {
      const response = await this.fetcher(`https://${this.resource}/${name}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(data),
        signal: abort.signal,
      });
      if (!response.ok) {
        throw new Error(`status ${response.status}`);
      }
      /** @type {unknown} */
      const answer = await response.json();
      if (typeof answer !== "object" || answer === null || !("ok" in answer) || typeof answer.ok !== "boolean") {
        throw new Error("an answer without ok");
      }
      if (answer.ok) {
        return { ok: true };
      }
      const error = "error" in answer && typeof answer.error === "string" ? answer.error : "That did not work.";
      return { ok: false, error };
    } catch (error) {
      if (!options.quiet) {
        // The name and why only: what was sent may hold a sealed password's
        // handle, and an answer may hold a portal response.
        this.report(`rpf: the NUI callback "${name}" failed: ${reason(error)}`);
      }
      return { ok: false, error: UNANSWERED, unanswered: true };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Makes an HTTP request for the client's core and hands back the answer
   * through the `http` callback. Status 0 means no response arrived, as the
   * platform interface says. If the answer cannot be handed back, `call`
   * reports it, and `ui.lua` answers the request status 0 at its deadline.
   * @param {Record<string, unknown>} message The request, from `ui.lua`.
   * @param {Unsealer} sealed The page's sealed passwords.
   * @returns {Promise<Answer>} The `http` callback's answer.
   */
  async http(message, sealed) {
    const headers = /** @type {Record<string, string>} */ (message.headers ?? {});
    let status = 0;
    let body = "";
    /** @type {Record<string, string>} */
    let received = {};
    // A portal or proxy that stalls would otherwise leave the login waiting
    // for ever; abandoned, it is status 0, an outage the core reports and lets
    // the player retry. The bound covers the body as well as the headers.
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), this.httpTimeoutMs);
    try {
      const response = await this.fetcher(String(message.url), {
        method: String(message.method),
        headers,
        body: sealed.unseal(typeof message.body === "string" ? message.body : null),
        signal: abort.signal,
      });
      body = await response.text();
      status = response.status;
      received = Object.fromEntries(response.headers.entries());
    } catch {
      status = 0;
      body = "";
    } finally {
      clearTimeout(timer);
    }
    return this.call("http", { id: message.id, status, body, headers: received });
  }
}

/**
 * Why something failed, in a few words, for the console.
 * @param {unknown} error What was thrown.
 * @returns {string} Its name and message.
 */
function reason(error) {
  if (error instanceof Error) {
    if (error.name === "AbortError") {
      return "no answer in time";
    }
    // A JSON error quotes what it could not read; say only that it was not JSON.
    return error.name === "SyntaxError" ? "an answer that is not JSON" : `${error.name}: ${error.message}`;
  }
  return String(error);
}
