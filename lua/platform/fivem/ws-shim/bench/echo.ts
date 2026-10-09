/**
 * A websocket echo server for `rpf_dev_bench` (`../dev.lua`), the shim
 * benchmark on a real FXServer: every frame comes back as it arrived.
 *
 *   npm run echo               # ws://127.0.0.1:30121
 *   ECHO_PORT=0 npm run echo   # any free port, printed
 */

import { WebSocketServer } from "ws";

const port = Number(process.env.ECHO_PORT ?? 30121);
const echo = new WebSocketServer({ host: "127.0.0.1", port });
echo.on("connection", (socket) => socket.on("message", (data, binary) => socket.send(data, { binary })));
echo.once("listening", () => {
  const address = echo.address();
  if (typeof address === "object" && address !== null) {
    console.log(`echo server on ws://127.0.0.1:${address.port}`);
  }
});
