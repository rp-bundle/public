// rpf_inventory's NUI page. It draws the view the client script sends
// (`view`), puts each item's image on its tiles as it arrives (`image`), and
// posts what the player picks back to the client script (`command`), which
// asks the server. Every name on it is someone's text (staff name items and
// containers, players name characters), so it only ever goes in as text.
"use strict";

/** The resource's name, which the client script's callbacks are under. */
const RESOURCE = typeof GetParentResourceName === "function" ? GetParentResourceName() : "rpf_inventory";

/** The view the server last answered, and the images that have arrived, by item. */
const state = { view: null, images: new Map() };

const root = document.getElementById("inventory");
const notice = document.getElementById("notice");
const money = document.getElementById("money");
const containers = document.getElementById("containers");
const menu = document.getElementById("menu");

/** Posts to one of the client script's callbacks, and gives its answer. */
async function post(name, body) {
	const response = await fetch(`https://${RESOURCE}/${name}`, {
		method: "POST",
		headers: { "Content-Type": "application/json; charset=UTF-8" },
		body: JSON.stringify(body ?? {}),
	});
	return response.json();
}

/** A list from the view: Lua sends an empty table as `{}` as often as `[]`. */
function list(value) {
	return Array.isArray(value) ? value : [];
}

/** An element with a class and, optionally, text. */
function element(tag, className, text) {
	const node = document.createElement(tag);
	if (className) node.className = className;
	if (text !== undefined) node.textContent = String(text);
	return node;
}

/** Shows a line above the inventory: a refusal, or that something worked. */
function tell(message, good) {
	notice.textContent = message ?? "";
	notice.classList.toggle("good", Boolean(good));
}

/** Closes the inventory, giving the mouse back to the game. */
function close() {
	hideMenu();
	root.hidden = true;
	post("close");
}

/** Hides the action menu. */
function hideMenu() {
	menu.hidden = true;
	menu.replaceChildren();
}

/** Sends a command and says how it went; the client script reloads the view. */
async function command(action, payload) {
	hideMenu();
	const answer = await post("command", { action, payload });
	tell(answer.ok ? "Done." : answer.message, answer.ok);
}

/** A whole number from a field, within bounds, or null. */
function wholeIn(input, low, high) {
	const value = Number(input.value);
	return Number.isInteger(value) && value >= low && value <= high ? value : null;
}

/** A labelled number field for a count, starting at its most. */
function countField(label, most) {
	const wrap = element("label", null, label);
	const input = element("input");
	input.type = "number";
	input.min = "1";
	input.max = String(most);
	input.value = String(most);
	wrap.append(input);
	return { wrap, input };
}

/** A select of the players near enough to be given something. */
function playerField() {
	const select = element("select");
	for (const player of list(state.view.nearby)) {
		const option = element("option", null, player.name);
		option.value = player.id;
		select.append(option);
	}
	return select;
}

/** Opens the action menu for a stack at a point on the screen. */
function stackMenu(container, stack, x, y) {
	hideMenu();
	const view = state.view;
	const ref = { container: container.id, index: stack.index, item: stack.item, key: stack.key };
	menu.append(element("strong", null, stack.name ?? stack.item));
	if (stack.usable) {
		const use = element("button", null, "Use");
		use.addEventListener("click", () => command("use", { stack: ref }));
		menu.append(use);
	}
	const count = countField("How many", stack.count);
	menu.append(count.wrap);
	for (const other of list(view.containers)) {
		if (other.id !== container.id) {
			const move = element("button", null, `Move to ${other.name}`);
			move.addEventListener("click", () => {
				const n = wholeIn(count.input, 1, stack.count);
				if (n !== null) command("move", { stack: ref, to: other.id, count: n });
			});
			menu.append(move);
		}
	}
	if (view.allow.give && list(view.nearby).length > 0) {
		const who = playerField();
		const give = element("button", null, "Give");
		give.addEventListener("click", () => {
			const n = wholeIn(count.input, 1, stack.count);
			if (n !== null) command("give", { stack: ref, to: who.value, count: n });
		});
		menu.append(who, give);
	}
	if (view.allow.drop) {
		const drop = element("button", null, "Throw away");
		drop.addEventListener("click", () => {
			const n = wholeIn(count.input, 1, stack.count);
			if (n !== null) command("drop", { stack: ref, count: n });
		});
		menu.append(drop);
	}
	menu.style.left = `${Math.min(x, window.innerWidth - 200)}px`;
	menu.style.top = `${Math.min(y, window.innerHeight - 260)}px`;
	menu.hidden = false;
}

/** Opens the menu for handing cash to a player nearby. */
function cashMenu(x, y) {
	hideMenu();
	const view = state.view;
	const amount = countField("Amount", 1);
	amount.input.removeAttribute("max");
	const who = playerField();
	const send = element("button", null, "Hand over");
	send.addEventListener("click", () => {
		const n = wholeIn(amount.input, 1, Number.MAX_SAFE_INTEGER);
		if (n !== null) command("cash", { amount: n, to: who.value });
	});
	menu.append(element("strong", null, `Hand over ${view.cash_account}`), amount.wrap, who, send);
	menu.style.left = `${Math.min(x, window.innerWidth - 200)}px`;
	menu.style.top = `${Math.min(y, window.innerHeight - 200)}px`;
	menu.hidden = false;
}

/** A stack's tile: its image when it has arrived, its name and count. */
function tile(container, stack) {
	const button = element("button", stack.special ? "tile special" : "tile");
	button.title = stack.special ? `${stack.name ?? stack.item} (one of a kind)` : stack.name ?? stack.item;
	const src = state.images.get(stack.item);
	if (src) {
		const img = element("img");
		img.alt = "";
		img.src = src;
		button.append(img);
	}
	button.append(element("span", "name", stack.name ?? stack.item), element("span", "count", `×${stack.count}`));
	button.addEventListener("click", (event) => stackMenu(container, stack, event.clientX, event.clientY));
	return button;
}

/** Draws the whole view. */
function draw() {
	const view = state.view;
	if (!view) return;
	money.replaceChildren();
	const balances = element("div", "balances");
	for (const account of list(view.money)) {
		const box = element("div", "balance");
		box.append(element("strong", null, account.balance.toLocaleString()), element("span", null, account.account));
		balances.append(box);
	}
	if (view.allow.cash && list(view.nearby).length > 0) {
		const cash = element("button", null, "Hand over cash");
		cash.addEventListener("click", (event) => cashMenu(event.clientX, event.clientY));
		balances.append(cash);
	}
	money.append(balances);
	containers.replaceChildren();
	if (!view.items) {
		containers.append(element("p", null, "This server's own inventory holds your items."));
		return;
	}
	for (const container of list(view.containers)) {
		const heading = element("h2", null, container.name);
		const weight = container.max_weight == null ? `${container.weight}` : `${container.weight} / ${container.max_weight}`;
		heading.append(" ", element("span", "weight", weight));
		const tiles = element("div", "tiles");
		for (const stack of list(container.stacks)) tiles.append(tile(container, stack));
		if (list(container.stacks).length === 0) tiles.append(element("p", null, "Empty."));
		containers.append(heading, tiles);
	}
}

window.addEventListener("message", (event) => {
	const message = event.data ?? {};
	if (message.type === "open") {
		state.view = null;
		tell("");
		containers.replaceChildren(element("p", null, "Loading…"));
		money.replaceChildren();
		root.hidden = false;
	} else if (message.type === "view") {
		state.view = message.view;
		if (message.error) tell(message.error);
		draw();
	} else if (message.type === "image") {
		state.images.set(message.item, message.src);
		draw();
	} else if (message.type === "error") {
		tell(message.message);
		containers.replaceChildren();
	}
});

document.getElementById("close").addEventListener("click", close);
window.addEventListener("keydown", (event) => {
	if (event.key === "Escape") {
		if (!menu.hidden) hideMenu();
		else close();
	}
});
