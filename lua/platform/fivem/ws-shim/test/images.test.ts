/**
 * The NUI page's item images (`../nui/images.js`, P3): fetched with the
 * token only as far as the portal, checked against their hash, kept under
 * it, and handed back as a PNG `data:` URL.
 */

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";

import { ItemImages, MAX_KEPT, MemoryStore, OX_LIB_ICON } from "../../nui/images.js";

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const HASH = createHash("sha256").update(PNG).digest("hex");
const URL_ON_PORTAL = `https://portal.example/api/v1/player/items/apple/image?v=${HASH}`;
const SIGNED = "https://usercontent.example/items/g/k.png?X-Amz-Signature=s";
const HEADERS = { Authorization: "Bearer rpf_at_token.mac" };

type Call = { url: string; headers: Record<string, string> };

/**
 * A fetch that answers each call with the next response, recording what it
 * was asked. A response is a body and a status, and whether (and where) a
 * redirect took it.
 */
function fetcher(responses: { status: number; body?: Uint8Array<ArrayBuffer>; redirectedTo?: string }[]) {
  const calls: Call[] = [];
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), headers: { ...((init?.headers ?? {}) as Record<string, string>) } });
    const next = responses.shift();
    assert.ok(next, "an unexpected fetch");
    const response = new Response(next.body ?? new Uint8Array(), { status: next.status });
    if (next.redirectedTo) {
      Object.defineProperty(response, "redirected", { value: true });
      Object.defineProperty(response, "url", { value: next.redirectedTo });
    } else {
      Object.defineProperty(response, "url", { value: String(input) });
    }
    return response;
  }) as typeof fetch;
  return { fn, calls };
}

describe("item images", () => {
  it("fetch one with the token, check its hash, and hand back a PNG data URL", async () => {
    const { fn, calls } = fetcher([{ status: 200, body: PNG, redirectedTo: SIGNED }]);
    const images = new ItemImages(new MemoryStore(), fn);
    const answer = await images.get(URL_ON_PORTAL, HEADERS, HASH);
    assert.deepEqual(answer, { src: `data:image/png;base64,${Buffer.from(PNG).toString("base64")}#.png` });
    assert.deepEqual(calls, [{ url: URL_ON_PORTAL, headers: HEADERS }]);
  });

  it("end with a fragment ox_lib's isIconUrl takes for an image, which leaves the bytes as they are", async () => {
    const { fn } = fetcher([{ status: 200, body: PNG }]);
    const answer = await new ItemImages(new MemoryStore(), fn).get(URL_ON_PORTAL, HEADERS, HASH);
    assert.ok("src" in answer);
    // ox_lib 3.40.0's web/src/utils/isIconUrl.ts, as pinned in dev/fivem-natives.
    const isIconUrl = (icon: string) => icon.includes("://") || icon.includes(".png") || icon.includes(".webp");
    assert.ok(isIconUrl(answer.src));
    assert.ok(answer.src.endsWith(OX_LIB_ICON));
    // A fetch of the data: URL, as an <img> loads it, drops the fragment.
    const loaded = new Uint8Array(await (await fetch(answer.src)).arrayBuffer());
    assert.deepEqual(loaded, PNG);
  });

  it("keep it under its hash: asked again, nothing is fetched", async () => {
    const { fn, calls } = fetcher([{ status: 200, body: PNG }]);
    const images = new ItemImages(new MemoryStore(), fn);
    const first = await images.get(URL_ON_PORTAL, HEADERS, HASH);
    const again = await images.get(URL_ON_PORTAL, HEADERS, HASH);
    assert.deepEqual(again, first);
    assert.equal(calls.length, 1);
  });

  it("fetch one hash once however many ask at a time", async () => {
    const { fn, calls } = fetcher([{ status: 200, body: PNG }]);
    const images = new ItemImages(new MemoryStore(), fn);
    const [a, b] = await Promise.all([
      images.get(URL_ON_PORTAL, HEADERS, HASH),
      images.get(URL_ON_PORTAL, HEADERS, HASH),
    ]);
    assert.deepEqual(a, b);
    assert.equal(calls.length, 1);
  });

  it("refuse bytes that are not the hash asked for, and keep nothing", async () => {
    const other = new Uint8Array([9, 9, 9]);
    const { fn, calls } = fetcher([
      { status: 200, body: other },
      { status: 200, body: PNG },
    ]);
    const images = new ItemImages(new MemoryStore(), fn);
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, HASH), { error: "unavailable" });
    assert.ok("src" in (await images.get(URL_ON_PORTAL, HEADERS, HASH)), "fetched again, not kept");
    assert.equal(calls.length, 2);
  });

  it("say not_found for the portal's 404, and unavailable for storage's or anything else", async () => {
    const { fn } = fetcher([
      { status: 404 },
      { status: 404, redirectedTo: "https://portal.example/elsewhere" },
      { status: 500 },
    ]);
    const images = new ItemImages(new MemoryStore(), fn);
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, HASH), { error: "not_found" });
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, HASH), { error: "unavailable" });
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, HASH), { error: "unavailable" });
  });

  it("refuse a hash that is not one, without fetching", async () => {
    const { fn, calls } = fetcher([]);
    const images = new ItemImages(new MemoryStore(), fn);
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, "../../etc"), { error: "unavailable" });
    assert.equal(calls.length, 0);
  });

  it("answer unavailable when the fetch itself fails", async () => {
    const fn = (async () => {
      throw new TypeError("network");
    }) as typeof fetch;
    const images = new ItemImages(new MemoryStore(), fn);
    assert.deepEqual(await images.get(URL_ON_PORTAL, HEADERS, HASH), { error: "unavailable" });
  });

  it("are kept up to MAX_KEPT, the least recently used dropped first", async () => {
    const store = new MemoryStore();
    for (let i = 0; i <= MAX_KEPT; i += 1) {
      await store.put(i.toString(16).padStart(64, "0"), `src${i}`);
    }
    assert.equal(store.kept.size, MAX_KEPT);
    assert.equal(await store.get("0".padStart(64, "0")), null, "the oldest went");
    assert.equal(await store.get("1".padStart(64, "0")), "src1");
  });
});
