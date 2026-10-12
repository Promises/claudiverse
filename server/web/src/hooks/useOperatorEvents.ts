import { useEffect, useRef } from "react";
import type { Channel } from "phoenix";
import { getSocket } from "../lib/socket";

export type OperatorEvent = Record<string, unknown>;

const TOPIC = "operator:events";

/**
 * The operator's events (`host`, `host_spawn`, …) from operator:events, each
 * to the latest `onEvent`. One subscriber per topic, as useSession: a stale
 * channel left by StrictMode's mount → cleanup → mount is removed first.
 */
export function useOperatorEvents(
  token: string | null,
  events: readonly string[],
  onEvent: (event: string, payload: OperatorEvent) => void,
) {
  const handler = useRef(onEvent);
  useEffect(() => {
    handler.current = onEvent;
  });

  const names = events.join(" ");
  useEffect(() => {
    if (!token) return;
    const socket = getSocket(token);
    const sock = socket as unknown as { channels: Channel[]; remove: (c: Channel) => void };
    const stale = sock.channels?.find((c) => c.topic === TOPIC);
    if (stale) sock.remove(stale);

    const channel = socket.channel(TOPIC, {});
    for (const name of names.split(" ")) channel.on(name, (payload: OperatorEvent) => handler.current(name, payload));
    channel.join().receive("error", (err) => console.error("operator:events join error:", err));
    return () => {
      channel.leave();
    };
  }, [token, names]);
}
