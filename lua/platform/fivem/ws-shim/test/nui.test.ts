/**
 * The NUI page's password sealing (`../nui/seal.js`): a password the core
 * sends a request with arrives at the portal as the player typed it, and
 * never existed in Lua.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { PREFIX, Sealed } from "../../nui/seal.js";

describe("sealed passwords", () => {
  it("are handles that swap back to the password in a request body", () => {
    const sealed = new Sealed();
    // Characters JSON escapes, so the swap must write the JSON form.
    const password = 'p"ss\\wörd\n✓';
    const handle = sealed.seal(password);
    assert.ok(handle.startsWith(PREFIX));
    assert.ok(!handle.includes(password));
    assert.match(handle, /^[a-z0-9-]+$/, "safe to put in JSON as is");

    const body = JSON.stringify({ username: "sam", password: handle, nonce: "rpf_jn_x" });
    const sent = sealed.unseal(body);
    assert.deepEqual(JSON.parse(sent!), { username: "sam", password, nonce: "rpf_jn_x" });
  });

  it("swap back in an account deletion's body, the same as a login's", () => {
    const sealed = new Sealed();
    const handle = sealed.seal("hunter2");
    const body = JSON.stringify({ nonce: "rpf_jn_x", username: "sam", password: handle });
    assert.deepEqual(JSON.parse(sealed.unseal(body)!), { nonce: "rpf_jn_x", username: "sam", password: "hunter2" });
  });

  it("swap each of several, and leave anything else alone", () => {
    const sealed = new Sealed();
    const old = sealed.seal("old one");
    const next = sealed.seal("new one");
    const body = JSON.stringify({ password: old, new_password: next, note: `${old} inside text` });
    assert.deepEqual(JSON.parse(sealed.unseal(body)!), {
      password: "old one",
      new_password: "new one",
      note: `${old} inside text`,
    });
    assert.equal(sealed.unseal(null), null);
  });

  it("are forgotten once cleared", () => {
    const sealed = new Sealed();
    const handle = sealed.seal("secret");
    sealed.clear();
    const body = JSON.stringify({ password: handle });
    assert.equal(sealed.unseal(body), body);
  });

  it("forget only a refused submission's, keeping an attempt still under way", () => {
    const sealed = new Sealed();
    const waiting = sealed.seal("first");
    const refused = sealed.seal("second");
    sealed.forget([refused]);
    const body = JSON.stringify({ password: waiting, other: refused });
    assert.deepEqual(JSON.parse(sealed.unseal(body)!), { password: "first", other: refused });
  });

  it("are never the same twice", () => {
    const sealed = new Sealed();
    assert.notEqual(sealed.seal("x"), sealed.seal("x"));
  });
});
