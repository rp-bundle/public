/**
 * What the shim's tests share: a local websocket server standing in for the
 * portal, and a recorder for the events the shim emits.
 */

import type { AddressInfo } from "node:net";
import { type WebSocket, WebSocketServer } from "ws";

import type { WsEvents } from "../src/contract.ts";
import type { Emit } from "../src/hub.ts";

/** One event the shim emitted, by name, with its arguments. */
export type Recorded = { [K in keyof WsEvents]: { name: K; args: Parameters<WsEvents[K]> } }[keyof WsEvents];

/** Records every event, and lets a test wait for one. */
export class Recorder {
  readonly events: Recorded[] = [];
  #waiters: (() => void)[] = [];

  /** The `emit` to hand the hub. */
  readonly emit: Emit = (name, ...args) => {
    this.events.push({ name, args } as Recorded);
    for (const wake of this.#waiters.splice(0)) {
      wake();
    }
  };

  /**
   * Waits until a predicate holds over what has been recorded.
   * @param what Says what is awaited, for the timeout's message.
   * @param done The predicate.
   * @param ms How long to wait.
   */
  async until(what: string, done: (events: Recorded[]) => boolean, ms = 5_000): Promise<void> {
    const deadline = Date.now() + ms;
    while (!done(this.events)) {
      const left = deadline - Date.now();
      if (left <= 0) {
        throw new Error(`timed out waiting for ${what}; saw ${JSON.stringify(this.events)}`);
      }
      await new Promise<void>((wake) => {
        const timer = setTimeout(wake, left);
        this.#waiters.push(() => {
          clearTimeout(timer);
          wake();
        });
      });
    }
  }

  /**
   * The events for one connection.
   * @param id The connection.
   * @returns events Its events, in order.
   */
  of(id: number): Recorded[] {
    return this.events.filter((event) => event.args[0] === id);
  }
}

/** A local websocket server that records what it receives and keeps its sockets. */
export class Portal {
  readonly server: WebSocketServer;
  readonly received: string[] = [];
  readonly sockets: WebSocket[] = [];

  private constructor(server: WebSocketServer) {
    this.server = server;
    server.on("connection", (socket) => {
      this.sockets.push(socket);
      socket.on("message", (data, isBinary) => {
        if (!isBinary) {
          this.received.push(data.toString("utf8"));
        }
      });
    });
  }

  /**
   * Starts one on a free local port.
   * @returns portal The running server.
   */
  static async start(): Promise<Portal> {
    const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
    await new Promise<void>((ready) => server.once("listening", ready));
    return new Portal(server);
  }

  /** The `ws://` url it listens on. */
  get url(): string {
    const { port } = this.server.address() as AddressInfo;
    return `ws://127.0.0.1:${port}/ws`;
  }

  /** Stops it, closing every socket. */
  async stop(): Promise<void> {
    for (const socket of this.server.clients) {
      socket.terminate();
    }
    await new Promise<void>((done) => this.server.close(() => done()));
  }
}
