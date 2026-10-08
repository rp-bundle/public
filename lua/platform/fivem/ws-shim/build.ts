/**
 * Bundles the shim, `ws` included, into `dist/rpf-ws.js`: one file the
 * resource's manifest loads, so a server owner needs no `npm install`. Not
 * minified, so an owner can read what they run.
 *
 * The target is the oldest Node a supported FXServer ships (16). `ws`'s two
 * optional native helpers are left out: it falls back to plain JS without
 * them, and a native module cannot be bundled.
 */

import { build } from "esbuild";

await build({
  entryPoints: ["src/main.ts"],
  outfile: "dist/rpf-ws.js",
  bundle: true,
  platform: "node",
  target: "node16",
  format: "cjs",
  external: ["bufferutil", "utf-8-validate"],
  legalComments: "inline",
  logLevel: "warning",
});
