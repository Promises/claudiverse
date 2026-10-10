import { useState, useEffect, useCallback, useRef } from "react";
import { Channel } from "phoenix";
import { getSocket } from "../lib/socket";
import type { SDKMessage, PermissionRequest } from "../lib/types";

interface UseSessionOptions {
  sessionId: number;
  token: string;
  role?: "observer" | "sidecar";
}

interface UseSessionReturn {
  messages: SDKMessage[];
  permissionRequests: PermissionRequest[];
  connected: boolean;
  sendMessage: (content: string) => void;
  respondToPermission: (requestId: string, decision: "allow" | "deny") => void;
  interrupt: () => void;
}

export function useSession({
  sessionId,
  token,
  role = "observer",
}: UseSessionOptions): UseSessionReturn {
  const [messages, setMessages] = useState<SDKMessage[]>([]);
  const [permissionRequests, setPermissionRequests] = useState<PermissionRequest[]>([]);
  const [connected, setConnected] = useState(false);
  const channelRef = useRef<Channel | null>(null);

  useEffect(() => {
    const socket = getSocket(token);
    const topic = `session:${sessionId}`;

    // ⛔ DROP ANY EXISTING CHANNEL ON THIS TOPIC FIRST. channel.leave() is
    //    ASYNCHRONOUS, so under StrictMode's mount → cleanup → mount the second
    //    join lands while the first channel is still subscribed — two Channel
    //    objects on one topic, and every broadcast delivered to both. Removing
    //    it synchronously means there is only ever one subscriber per topic.
    // `channels` is real on the Phoenix Socket but absent from its TS types,
    // hence the cast — narrow to exactly what is used rather than `any`.
    const sock = socket as unknown as {
      channels: Channel[];
      remove: (c: Channel) => void;
    };
    const stale = sock.channels?.find((c) => c.topic === topic);
    if (stale) sock.remove(stale);

    const channel = socket.channel(topic, { role });

    channel
      .join()
      .receive("ok", () => setConnected(true))
      .receive("error", (err) => console.error("Join error:", err));

    // A replay also carries the prompts asked before this page joined (an
    // older server sends none), so they can still be answered here.
    channel.on("replay", (payload: { messages: SDKMessage[]; pending_permissions?: PermissionRequest[] }) => {
      setMessages(payload.messages);
      setPermissionRequests(payload.pending_permissions ?? []);
    });

    channel.on("message", (msg: SDKMessage) => {
      setMessages((prev) => {
        // Defence in depth against a re-delivery the fixes above did not
        // prevent. Keyed on the message's own uuid ONLY — content is not a safe
        // key here, because identical stream_event payloads legitimately recur
        // many times in a turn and de-duplicating those would drop real data.
        const uuid = (msg as unknown as { uuid?: string }).uuid;
        if (uuid && prev.some((m) => (m as unknown as { uuid?: string }).uuid === uuid)) {
          return prev;
        }
        return [...prev, msg];
      });
    });

    channel.on("permission_request", (req: PermissionRequest) => {
      setPermissionRequests((prev) => [...prev, req]);
    });

    channel.on("permission_resolved", (payload: { request_id: string }) => {
      setPermissionRequests((prev) =>
        prev.filter((r) => r.request_id !== payload.request_id)
      );
    });

    channel.on("session_ended", () => {
      setConnected(false);
    });

    channelRef.current = channel;

    return () => {
      channel.leave();
      channelRef.current = null;
      setConnected(false);
    };
  }, [sessionId, token, role]);

  const sendMessage = useCallback((content: string) => {
    channelRef.current?.push("send_message", { content });
  }, []);

  const respondToPermission = useCallback(
    (requestId: string, decision: "allow" | "deny") => {
      channelRef.current?.push("permission_response", {
        request_id: requestId,
        decision,
      });
    },
    []
  );

  const interrupt = useCallback(() => {
    channelRef.current?.push("interrupt", {});
  }, []);

  return {
    messages,
    permissionRequests,
    connected,
    sendMessage,
    respondToPermission,
    interrupt,
  };
}
