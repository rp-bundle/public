// @ts-check
/**
 * Item images on the FiveM client (P3, #243): the engine half of
 * `rpf.items.image`. The core hands this page the image's URL on the portal,
 * the player's API token as a header, and the image's content hash; this
 * fetches it, checks it, keeps it under its hash, and answers with a
 * `data:` URL, which any resource's page can put in an `<img>` and ox_lib
 * takes as an `image` or `icon`. A blob URL would not do: it belongs to
 * this page's origin and dies with it.
 *
 * - **The token goes only to the portal, in a header.** `fetch` follows the
 *   portal's `302` to the user-content domain and drops `Authorization` on
 *   the way, as the Fetch standard requires for a cross-origin redirect: the
 *   signed URL is the credential there. A browser too old to drop it would
 *   send it on, and its CORS preflight to the user-content domain fails
 *   (storage allows no request headers), so the fetch rejects and the
 *   image is `unavailable`; nothing here can read the signed URL to try
 *   again without the token. Whether FiveM's CEF drops it is checked on a
 *   real client (#243).
 * - **The URL ends `#.png`.** ox_lib takes an `icon` as an image only if it
 *   contains `://`, `.png` or `.webp` (its `isIconUrl`), and draws anything
 *   else as a Font Awesome name. A fragment is not part of a `data:` URL's
 *   payload, so an `<img>` decodes it the same, and ox_lib sees an image.
 * - **Kept by hash, checked by hash.** Bytes whose SHA-256 is not the hash
 *   asked for are refused and never kept, so what is kept under a hash is
 *   always that image, and a hash once fetched is never fetched again, even
 *   after a restart (IndexedDB, where the page has it; memory otherwise).
 *   At most `MAX_KEPT` images are kept, the least recently used dropped.
 *
 * No framework and no build step: the resource ships this file as it is.
 */

/** How long one image fetch may take, headers and body, before it counts as failed. */
export const FETCH_TIMEOUT_MS = 30_000;

/** The most images kept, least recently used dropped first. */
export const MAX_KEPT = 512;

/** What a `data:` URL ends with so ox_lib's `isIconUrl` takes it for an image (above). */
export const OX_LIB_ICON = "#.png";

/** The largest image accepted, in bytes: far above what the portal stores (a 256-pixel PNG). */
export const MAX_BYTES = 1024 * 1024;

/**
 * Where images are kept, by hash.
 * @typedef {object} ImageStore
 * @property {(hash: string) => Promise<string | null>} get The `data:` URL kept under a hash, or null.
 * @property {(hash: string, src: string) => Promise<void>} put Keeps one, dropping the least recently used past `MAX_KEPT`.
 */

/**
 * What one request answers: the image, or why there is none.
 * @typedef {{ src: string } | { error: "not_found" | "unavailable" }} ImageAnswer
 */

/** Images kept in memory: the store when the page has no IndexedDB, and the test's. */
export class MemoryStore {
  constructor() {
    /** @type {Map<string, string>} In use order, oldest first. */
    this.kept = new Map();
  }

  /**
   * @param {string} hash The hash.
   * @returns {Promise<string | null>} The `data:` URL, or null.
   */
  async get(hash) {
    const src = this.kept.get(hash);
    if (src === undefined) {
      return null;
    }
    this.kept.delete(hash);
    this.kept.set(hash, src);
    return src;
  }

  /**
   * @param {string} hash The hash.
   * @param {string} src The `data:` URL.
   */
  async put(hash, src) {
    this.kept.delete(hash);
    this.kept.set(hash, src);
    for (const oldest of this.kept.keys()) {
      if (this.kept.size <= MAX_KEPT) {
        break;
      }
      this.kept.delete(oldest);
    }
  }
}

/**
 * Images kept in IndexedDB, which survives a restart of the game. Each
 * record is `{ hash, src, used }`, `used` a counter for dropping the least
 * recently used.
 */
export class IndexedDbStore {
  /**
   * @param {IDBDatabase} db The open database, with an `images` store keyed by `hash` and indexed by `used`.
   */
  constructor(db) {
    this.db = db;
    this.clock = Date.now();
  }

  /**
   * Opens the database, or resolves null where the page has none.
   * @returns {Promise<IndexedDbStore | null>} The store.
   */
  static async open() {
    if (typeof indexedDB === "undefined") {
      return null;
    }
    return await new Promise((resolve) => {
      const request = indexedDB.open("rpf-item-images", 1);
      request.onupgradeneeded = () => {
        const store = request.result.createObjectStore("images", { keyPath: "hash" });
        store.createIndex("used", "used");
      };
      request.onsuccess = () => resolve(new IndexedDbStore(request.result));
      request.onerror = () => resolve(null);
      request.onblocked = () => resolve(null);
    });
  }

  /**
   * A counter that only goes up, even if the clock steps back.
   * @returns {number} The next value.
   */
  tick() {
    this.clock = Math.max(this.clock + 1, Date.now());
    return this.clock;
  }

  /**
   * @param {string} hash The hash.
   * @returns {Promise<string | null>} The `data:` URL, or null.
   */
  async get(hash) {
    const used = this.tick();
    return await new Promise((resolve) => {
      const tx = this.db.transaction("images", "readwrite");
      const store = tx.objectStore("images");
      const request = store.get(hash);
      request.onsuccess = () => {
        const record = request.result;
        if (record && typeof record.src === "string") {
          store.put({ hash, src: record.src, used });
          resolve(record.src);
        } else {
          resolve(null);
        }
      };
      request.onerror = () => resolve(null);
    });
  }

  /**
   * @param {string} hash The hash.
   * @param {string} src The `data:` URL.
   */
  async put(hash, src) {
    const used = this.tick();
    await new Promise((resolve) => {
      const tx = this.db.transaction("images", "readwrite");
      const store = tx.objectStore("images");
      store.put({ hash, src, used });
      const count = store.count();
      count.onsuccess = () => {
        let extra = count.result - MAX_KEPT;
        if (extra <= 0) {
          return;
        }
        const cursor = store.index("used").openCursor();
        cursor.onsuccess = () => {
          const at = cursor.result;
          if (at && extra > 0) {
            extra -= 1;
            at.delete();
            at.continue();
          }
        };
      };
      tx.oncomplete = () => resolve(undefined);
      tx.onerror = () => resolve(undefined);
      tx.onabort = () => resolve(undefined);
    });
  }
}

/**
 * Lowercase hex of some bytes.
 * @param {ArrayBuffer} buffer The bytes.
 * @returns {string} The hex.
 */
function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/**
 * Base64 of some bytes, in chunks, so a large image never overflows the
 * argument list of `String.fromCharCode`.
 * @param {Uint8Array} bytes The bytes.
 * @returns {string} The base64.
 */
function base64(bytes) {
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  }
  return btoa(binary);
}

/** Fetches item images and keeps them by hash. */
export class ItemImages {
  /**
   * @param {ImageStore} store Where images are kept.
   * @param {typeof fetch} [fetcher] How to fetch: the page's `fetch`, or a test's.
   */
  constructor(store, fetcher = fetch) {
    this.store = store;
    this.fetcher = fetcher;
    /** @type {Map<string, Promise<ImageAnswer>>} Fetches in flight, by hash. */
    this.loading = new Map();
  }

  /**
   * The image under `hash`: kept, or fetched from `url` now. Never rejects.
   * @param {string} url The image's URL on the portal.
   * @param {Record<string, string>} headers The request's headers, with the token.
   * @param {string} hash The image's SHA-256, lowercase hex.
   * @returns {Promise<ImageAnswer>} The answer.
   */
  async get(url, headers, hash) {
    if (!/^[0-9a-f]{64}$/.test(hash)) {
      return { error: "unavailable" };
    }
    const kept = await this.store.get(hash).catch(() => null);
    if (kept) {
      return { src: kept };
    }
    let loading = this.loading.get(hash);
    if (!loading) {
      loading = this.fetchAndKeep(url, headers, hash).finally(() => this.loading.delete(hash));
      this.loading.set(hash, loading);
    }
    return await loading;
  }

  /**
   * Fetches one image, checks it, and keeps it.
   * @param {string} url The image's URL on the portal.
   * @param {Record<string, string>} headers The request's headers.
   * @param {string} hash The image's hash.
   * @returns {Promise<ImageAnswer>} The answer.
   */
  async fetchAndKeep(url, headers, hash) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), FETCH_TIMEOUT_MS);
    try {
      const response = await this.fetcher(url, { headers, signal: abort.signal, credentials: "omit" });
      if (response.status === 404 && !response.redirected) {
        return { error: "not_found" };
      }
      if (!response.ok) {
        return { error: "unavailable" };
      }
      const bytes = await response.arrayBuffer();
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES) {
        return { error: "unavailable" };
      }
      if (hex(await crypto.subtle.digest("SHA-256", bytes)) !== hash) {
        return { error: "unavailable" };
      }
      const src = `data:image/png;base64,${base64(new Uint8Array(bytes))}${OX_LIB_ICON}`;
      await this.store.put(hash, src).catch(() => undefined);
      return { src };
    } catch {
      return { error: "unavailable" };
    } finally {
      clearTimeout(timer);
    }
  }
}
