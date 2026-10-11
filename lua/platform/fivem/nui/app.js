// @ts-check
/**
 * The login and character screens (D2). `ui.lua` decides what is shown and
 * sends it here with `SendNuiMessage`; what the player does goes back
 * through NUI callbacks. This page also makes the client's HTTP requests to
 * the portal with `fetch`, because FiveM's client Lua has none, and it is
 * the only place a password ever is (`seal.js`).
 *
 * No framework and no build step: the resource ships these files as they
 * are.
 */

import { Bridge } from "./bridge.js";
import { IndexedDbStore, ItemImages, MemoryStore } from "./images.js";
import { Sealed } from "./seal.js";

const sealed = new Sealed();

/** Item images (`images.js`), kept in IndexedDB where the page has it. */
const itemImages = IndexedDbStore.open()
  .catch(() => null)
  .then((store) => new ItemImages(store ?? new MemoryStore()));

/**
 * The resource this page belongs to, which names its NUI callbacks. FiveM
 * defines `GetParentResourceName` on NUI pages.
 * @returns {string} The resource name.
 */
function resource() {
  const named = /** @type {{ GetParentResourceName?: () => string }} */ (/** @type {unknown} */ (window));
  return named.GetParentResourceName ? named.GetParentResourceName() : "rpf";
}

/** NUI callbacks and portal requests (`bridge.js`). */
const bridge = new Bridge({ resource: resource() });

/**
 * Calls one of `ui.lua`'s NUI callbacks.
 * @param {string} name The callback.
 * @param {object} data What to send.
 * @param {{ quiet?: boolean }} [options] Whether to leave a failure out of the console.
 * @returns {Promise<import("./bridge.js").Answer>} Its answer, or `UNANSWERED` if there was none.
 */
function call(name, data, options) {
  return bridge.call(name, data, options);
}

/**
 * An element by id, which the page is known to have.
 * @param {string} id The id.
 * @returns {HTMLElement} The element.
 */
function byId(id) {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`missing #${id}`);
  }
  return element;
}

/**
 * Shows an error over the screen that is up, or hides it.
 * @param {string | null} message Written for the player.
 */
function showError(message) {
  const error = byId("error");
  error.textContent = message ?? "";
  error.hidden = message === null;
}

/**
 * Fills in the text a screen message carries.
 * @param {HTMLElement} section The screen.
 * @param {Record<string, unknown>} message The message.
 */
function fill(section, message) {
  for (const node of section.querySelectorAll("[data-warning]")) {
    node.textContent = typeof message.warning === "string" ? message.warning : "";
  }
  for (const node of section.querySelectorAll("[data-message]")) {
    node.textContent = typeof message.message === "string" ? message.message : "";
  }
  const username = section.querySelector('input[name="username"]');
  if (username instanceof HTMLInputElement && typeof message.username === "string") {
    username.value = message.username;
  }
}

/**
 * Lists characters as buttons that select them.
 * @param {unknown} characters The list, each `{ id, name }`.
 */
function list(characters) {
  const ul = byId("character-list");
  ul.replaceChildren();
  if (!Array.isArray(characters)) {
    return;
  }
  for (const character of characters) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = String(character.name);
    button.addEventListener("click", async () => {
      const answer = await call("select", { id: String(character.id) });
      if (!answer.ok) {
        showError(answer.error);
      }
    });
    li.append(button);
    ul.append(li);
  }
}

/**
 * Empties every password field, and unticks the delete form's confirmation so
 * a deletion is confirmed afresh each time the form is opened.
 */
function clearSecrets() {
  for (const input of document.querySelectorAll('input[type="password"]')) {
    if (input instanceof HTMLInputElement) {
      input.value = "";
    }
  }
  for (const input of document.querySelectorAll('input[name="confirmed"]')) {
    if (input instanceof HTMLInputElement) {
      input.checked = false;
    }
  }
}

/**
 * Whether the delete form was opened from the game (`ui.lua`'s `open_delete`,
 * for a player who is logged in) rather than from the login form. Back then
 * goes to `ui.lua`, which puts back the screen that was up, not to the login.
 */
let deleteFromGame = false;

/**
 * Shows one screen and hides the rest. A new screen ends any login attempt,
 * so the passwords it sealed are forgotten.
 * @param {Record<string, unknown>} message The screen message.
 */
function screen(message) {
  sealed.clear();
  showError(null);
  const name = String(message.screen);
  deleteFromGame = name === "delete" && message.from === "game";
  byId("panel").hidden = name === "closed";
  for (const section of document.querySelectorAll(".screen")) {
    if (section instanceof HTMLElement) {
      section.hidden = section.id !== name;
      if (section.id === name) {
        fill(section, message);
      }
    }
  }
  if (name === "characters") {
    list(message.characters);
  }
  clearSecrets();
}

/**
 * Fetches an item image for the client's core (`rpf.items.image`) and hands
 * back a `data:` URL, or why there is none. The token in `message.headers`
 * goes only to the portal, in a header.
 * @param {Record<string, unknown>} message The request.
 */
async function image(message) {
  const headers = /** @type {Record<string, string>} */ (message.headers ?? {});
  const images = await itemImages;
  const answer = await images.get(String(message.url), headers, String(message.hash));
  await call("image", { id: message.id, ...answer });
}

window.addEventListener("message", (event) => {
  const message = event.data;
  if (typeof message !== "object" || message === null) {
    return;
  }
  if (message.type === "screen") {
    screen(message);
  } else if (message.type === "error") {
    sealed.clear();
    showError(String(message.message));
  } else if (message.type === "http") {
    void bridge.http(message, sealed);
  } else if (message.type === "image") {
    void image(message);
  }
});

/**
 * Reads a form's fields as strings, with its checkbox as a boolean.
 * @param {HTMLFormElement} form The form.
 * @returns {Record<string, string>} The text fields.
 */
function fields(form) {
  /** @type {Record<string, string>} */
  const out = {};
  for (const [key, value] of new FormData(form)) {
    if (typeof value === "string") {
      out[key] = value;
    }
  }
  return out;
}

/**
 * Whether the form's "keep me logged in" box is ticked.
 * @param {HTMLFormElement} form The form.
 * @returns {boolean} Ticked or not.
 */
function remember(form) {
  const box = form.elements.namedItem("remember");
  return box instanceof HTMLInputElement ? box.checked : true;
}

/**
 * Sends a request that starts an attempt, and shows a refusal at once. A
 * refused submission forgets only its own passwords: an earlier attempt may
 * still be waiting for a nonce, and its request needs the ones it sealed. One
 * `ui.lua` never answered keeps them too, since it may have started.
 * @param {string} name The callback.
 * @param {object} data Its data, passwords already sealed.
 * @param {string[]} [handles] The handles sealed for this submission.
 */
async function attempt(name, data, handles = []) {
  showError(null);
  const answer = await call(name, data);
  if (!answer.ok) {
    if (!answer.unanswered) {
      sealed.forget(handles);
    }
    showError(answer.error);
  }
}

/**
 * The form an event came from.
 * @param {Event} event A submit event.
 * @returns {HTMLFormElement} The form.
 */
function formOf(event) {
  if (!(event.target instanceof HTMLFormElement)) {
    throw new Error("not a form");
  }
  return event.target;
}

byId("login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = formOf(event);
  const submitter = /** @type {SubmitEvent} */ (event).submitter;
  const action = submitter instanceof HTMLButtonElement && submitter.value === "register" ? "register" : "login";
  const { username = "", password = "" } = fields(form);
  const handle = sealed.seal(password);
  void attempt(action, { username, password: handle, remember: remember(form) }, [handle]);
});

byId("password-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = formOf(event);
  const { username = "", password = "", new_password = "" } = fields(form);
  const handles = [sealed.seal(password), sealed.seal(new_password)];
  void attempt(
    "change_password",
    { username, password: handles[0], new_password: handles[1], remember: remember(form) },
    handles,
  );
});

/**
 * Moves between the login form and the delete form without a message from
 * `ui.lua`, which would end a login still waiting for its nonce: only what is
 * shown changes, and the passwords typed on the screen left are cleared.
 * @param {"login" | "delete"} name The screen to show.
 */
function switchTo(name) {
  const from = byId(name === "delete" ? "login" : "delete");
  const typed = from.querySelector('input[name="username"]');
  showError(null);
  clearSecrets();
  byId("login").hidden = name !== "login";
  byId("delete").hidden = name !== "delete";
  const target = byId(name).querySelector('input[name="username"]');
  if (typed instanceof HTMLInputElement && target instanceof HTMLInputElement) {
    target.value = typed.value;
  }
}

byId("show-delete").addEventListener("click", () => switchTo("delete"));
byId("cancel-delete").addEventListener("click", () => {
  if (deleteFromGame) {
    void call("close_delete", {}).then((answer) => {
      if (!answer.ok) {
        showError(answer.error);
      }
    });
  } else {
    switchTo("login");
  }
});

byId("delete-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = formOf(event);
  const { username = "", password = "" } = fields(form);
  const box = form.elements.namedItem("confirmed");
  const confirmed = box instanceof HTMLInputElement && box.checked;
  const handle = sealed.seal(password);
  void attempt("delete_account", { username, password: handle, confirmed }, [handle]);
});

byId("refresh").addEventListener("click", () => {
  void attempt("refresh", {});
});

byId("create-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = formOf(event);
  const { first_name = "", last_name = "", gender = "female" } = fields(form);
  void attempt("create", { first_name, last_name, gender });
});

/**
 * Tells `ui.lua` the page is ready for its screens, until it answers: the
 * page can load before the client script has registered its callbacks, and
 * until it hears this the screens wait. The tries before that fail by
 * design, so only giving up is reported.
 */
async function announce() {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    const answer = await call("ready", {}, { quiet: true });
    if (answer.ok) {
      return;
    }
    await new Promise((wake) => setTimeout(wake, 500));
  }
  console.error('rpf: the NUI callback "ready" never answered; the login screen cannot be shown');
}

void announce();
