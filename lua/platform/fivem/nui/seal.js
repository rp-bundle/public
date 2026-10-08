// @ts-check
/**
 * Keeps passwords on this page (D2).
 *
 * The login form hands Lua a random handle in place of each password, and
 * the core puts the handle where the password goes in its request body.
 * Just before `fetch`, `unseal` swaps every handle in the body back for its
 * password, encoded as a JSON string. So a password goes from the form to
 * the portal without crossing into Lua or any FiveM event (P1).
 *
 * The swap is a plain string replacement, not a parse: a handle is a
 * JSON-safe token no other text contains, and it is replaced including its
 * quotes, so it cannot match inside another string.
 */

/** What every handle starts with, so a stray one is recognisable. */
export const PREFIX = "rpf-sealed-";

/** Handles to passwords, for the attempt under way. */
export class Sealed {
  /** @type {Map<string, string>} */
  #passwords = new Map();

  /**
   * Seals a password.
   * @param {string} password What the player typed.
   * @returns {string} The handle to send instead.
   */
  seal(password) {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    const handle = PREFIX + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    this.#passwords.set(handle, password);
    return handle;
  }

  /**
   * Swaps every handle in a request body for its password.
   * @param {string | null} body The body the core built.
   * @returns {string | null} The body to send.
   */
  unseal(body) {
    if (body === null) {
      return null;
    }
    let out = body;
    for (const [handle, password] of this.#passwords) {
      out = out.split(JSON.stringify(handle)).join(JSON.stringify(password));
    }
    return out;
  }

  /**
   * Forgets some passwords: those of a submission the core refused at once,
   * leaving any attempt still under way with its own.
   * @param {string[]} handles The handles that submission sealed.
   */
  forget(handles) {
    for (const handle of handles) {
      this.#passwords.delete(handle);
    }
  }

  /** Forgets every password, once the attempt is over. */
  clear() {
    this.#passwords.clear();
  }
}
