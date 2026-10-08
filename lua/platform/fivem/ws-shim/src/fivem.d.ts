/**
 * The two FiveM server JS globals the shim uses. Declared here rather than
 * pulled from `@citizenfx/server`, which types every native for the sake of
 * these two.
 */

/**
 * Registers an export of this resource, which Lua calls as
 * `exports["rpf-ws"]:<name>(...)`. Arguments and results cross as msgpack.
 * @param name The export's name.
 * @param fn What it runs.
 */
declare function exports(name: string, fn: (...args: never[]) => unknown): void;

/**
 * Triggers a server-local event (`TriggerEvent`), heard by every resource's
 * `AddEventHandler`. Never a network event: no client can send one.
 * @param name The event name.
 * @param args Its arguments, each serialised with msgpack.
 */
declare function emit(name: string, ...args: unknown[]): void;
