/**
 * The NUI page's bridge (`../nui/bridge.js`, #362): a NUI callback that
 * fails, stalls or answers nonsense is an answer the player sees and the
 * console records, never an empty one, and a portal request always hands
 * `ui.lua` an answer.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { Bridge, UNANSWERED } from "../../nui/bridge.js";
import { Sealed } from "../../nui/seal.js";

type Call = { url: string; body: string | null };

/**
 * A bridge over a fetch that answers each call with the next of `answers`:
 * a response, an error to reject with, or `"stall"`, which waits until
 * aborted.
 */
function bridge(answers: (Response | Error | "stall")[]) {
  const calls: Call[] = [];
  const reports: string[] = [];
  const fetcher = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: typeof init?.body === "string" ? init.body : null });
    const next = answers.shift();
    assert.ok(next, "an unexpected fetch");
    if (next === "stall") {
      return new Promise<Response>((_, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
      });
    }
    if (next instanceof Error) {
      throw next;
    }
    return next;
  }) as typeof fetch;
  const made = new Bridge({
    resource: "rpf",
    fetcher,
    report: (message) => reports.push(message),
    callbackTimeoutMs: 20,
    httpTimeoutMs: 20,
  });
  return { bridge: made, calls, reports };
}

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

describe("NUI callbacks", () => {
  it("pass on ui.lua's answer", async () => {
    const { bridge: b, calls, reports } = bridge([json({ ok: true }), json({ ok: false, error: "invalid" })]);
    assert.deepEqual(await b.call("login", { username: "sam" }), { ok: true });
    assert.deepEqual(await b.call("login", {}), { ok: false, error: "invalid" });
    assert.equal(calls[0]!.url, "https://rpf/login");
    assert.deepEqual(JSON.parse(calls[0]!.body!), { username: "sam" });
    assert.deepEqual(reports, []);
  });

  it("are unanswered, and say so, when the call fails, stalls or answers nonsense", async () => {
    const { bridge: b, reports } = bridge([
      new TypeError("Failed to fetch"),
      "stall",
      new Response("not json"),
      json({}),
      json({ ok: true }, 404),
    ]);
    for (let i = 0; i < 5; i += 1) {
      assert.deepEqual(await b.call("login", { password: "rpf-sealed-x" }), {
        ok: false,
        error: UNANSWERED,
        unanswered: true,
      });
    }
    assert.equal(reports.length, 5);
    assert.match(reports[0]!, /"login" failed: TypeError: Failed to fetch/);
    assert.match(reports[1]!, /no answer in time/);
    assert.match(reports[2]!, /not JSON/);
    for (const report of reports) {
      assert.ok(!report.includes("rpf-sealed-"), "never what was sent");
    }
  });

  it("leave a quiet failure out of the console", async () => {
    const { bridge: b, reports } = bridge([new TypeError("Failed to fetch")]);
    assert.equal((await b.call("ready", {}, { quiet: true })).ok, false);
    assert.deepEqual(reports, []);
  });
});

describe("portal requests", () => {
  it("unseal the body, and hand ui.lua the response", async () => {
    const sealed = new Sealed();
    const handle = sealed.seal("hunter2");
    const { bridge: b, calls } = bridge([
      new Response('{"ticket":"t"}', { status: 200, headers: { "X-Thing": "1" } }),
      json({ ok: true }),
    ]);
    const answer = await b.http(
      { id: 4, method: "POST", url: "https://portal.example/api/v1/player/login", body: JSON.stringify({ password: handle }) },
      sealed,
    );
    assert.deepEqual(answer, { ok: true });
    assert.deepEqual(JSON.parse(calls[0]!.body!), { password: "hunter2" });
    assert.equal(calls[1]!.url, "https://rpf/http");
    const handed = JSON.parse(calls[1]!.body!);
    assert.equal(handed.id, 4);
    assert.equal(handed.status, 200);
    assert.equal(handed.body, '{"ticket":"t"}');
    assert.equal(handed.headers["x-thing"], "1");
  });

  it("hand ui.lua status 0 when the portal fails or stalls", async () => {
    const { bridge: b, calls } = bridge([new TypeError("Failed to fetch"), json({ ok: true }), "stall", json({ ok: true })]);
    for (const id of [1, 2]) {
      await b.http({ id, method: "GET", url: "https://portal.example/x" }, new Sealed());
    }
    for (const handed of [calls[1]!, calls[3]!]) {
      assert.equal(JSON.parse(handed.body!).status, 0);
      assert.equal(JSON.parse(handed.body!).body, "");
    }
  });

  it("report an answer ui.lua did not take", async () => {
    const { bridge: b, reports } = bridge([json({}), new TypeError("Failed to fetch")]);
    const answer = await b.http({ id: 1, method: "GET", url: "https://portal.example/x" }, new Sealed());
    assert.equal(answer.ok, false);
    assert.equal(reports.length, 1);
    assert.match(reports[0]!, /"http" failed/);
  });
});
