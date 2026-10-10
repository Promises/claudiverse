import { Socket } from "phoenix";

const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";
const WS_URL = API_BASE.replace(/^http/, "ws") + "/socket";

let socket: Socket | null = null;

export function getSocket(token: string): Socket {
  // 🔴 REUSE UNLESS ACTUALLY CLOSED — NOT `isConnected()`.
  //
  // isConnected() is false while the handshake is still in flight, so a second
  // call during connect built an ENTIRELY NEW Socket and abandoned the first.
  // The old one stays open with its channels still subscribed, so every
  // broadcast arrives twice and messages appear duplicated in the panel.
  //
  // Two mounts racing the initial connect is the normal case, not a rare one:
  // React StrictMode runs effects mount → cleanup → mount in development, and
  // any second component subscribing before the socket finishes opening does it
  // in production too.
  if (socket && socket.connectionState() !== "closed") {
    return socket;
  }

  socket = new Socket(WS_URL, {
    params: { token },
  });

  socket.connect();
  return socket;
}

export function disconnectSocket() {
  if (socket) {
    socket.disconnect();
    socket = null;
  }
}
