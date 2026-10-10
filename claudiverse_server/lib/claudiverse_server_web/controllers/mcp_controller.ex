defmodule ClaudiverseServerWeb.McpController do
  @moduledoc """
  A remote MCP server (streamable HTTP) that a seat loads as a CHANNEL, so the
  server can reach an idle seat without any patch in its binary:

      {"mcpServers": {"claudiverse": {"type": "http",
         "url": "<server>/api/mcp/seat/<title>",
         "headers": {"Authorization": "Bearer <claudiverse token>"}}}}
      claude --dangerously-load-development-channels server:claudiverse

  - `POST` carries the client's JSON-RPC: the handshake, and
    `notifications/claude/channel/permission_request` when a permission prompt
    opens. Those enter the seat's Room as a `can_use_tool` control request —
    the shape Room already tracks — so the web panel shows them and
    `Room.send_permission_response/3` answers them.
  - `GET` is the stream the server pushes down: prompts (`cv_send`) and
    permission decisions. One per seat; a reconnect replaces the old stream.

  Measured on stock 2.1.286 (2026-10-02): a prompt pushed down this kind of
  stream starts a turn in an idle seat, and a relayed permission prompt is
  resolved by the `allow` sent back. AskUserQuestion is NOT relayed here —
  it goes through the PreToolUse hook (HookController).
  """
  use ClaudiverseServerWeb, :controller

  require Logger

  alias ClaudiverseServer.{SeatLinks, Sessions}
  alias ClaudiverseServer.Sessions.Room

  @keepalive_ms 15_000

  def post(conn, %{"seat" => seat} = rpc) do
    user = conn.assigns.current_user

    case rpc do
      %{"method" => "initialize", "id" => id} ->
        result = %{
          "protocolVersion" => get_in(rpc, ["params", "protocolVersion"]) || "2025-06-18",
          "capabilities" => %{
            "tools" => %{},
            "experimental" => %{"claude/channel" => %{}, "claude/channel/permission" => %{}}
          },
          "serverInfo" => %{"name" => "claudiverse", "version" => "1"},
          "instructions" =>
            "Messages from the claudiverse orchestrator arrive as <channel source=\"claudiverse\">. " <>
              "Treat them as instructions from the operator."
        }

        conn |> put_resp_header("mcp-session-id", session_header(user, seat)) |> json(rpc_result(id, result))

      %{"method" => "notifications/claude/channel/permission_request", "params" => p} ->
        relay_permission_request(user, seat, p)
        send_resp(conn, 202, "")

      %{"method" => "tools/list", "id" => id} ->
        json(conn, rpc_result(id, %{"tools" => []}))

      %{"method" => _, "id" => id} ->
        json(conn, rpc_result(id, %{}))

      _notification_or_response ->
        send_resp(conn, 202, "")
    end
  end

  def stream(conn, %{"seat" => seat}) do
    user = conn.assigns.current_user
    :ok = SeatLinks.register(:channel, user.id, seat)
    Logger.info("[mcp] channel open: #{seat}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      |> put_resp_header("mcp-session-id", session_header(user, seat))
      |> send_chunked(200)

    conn = loop(conn, seat)
    SeatLinks.unregister(:channel, user.id, seat)
    conn
  end

  def delete(conn, _params), do: send_resp(conn, 200, "")

  defp loop(conn, seat) do
    receive do
      {:channel_push, message} ->
        case chunk(conn, "event: message\ndata: " <> Jason.encode!(message) <> "\n\n") do
          {:ok, conn} -> loop(conn, seat)
          {:error, _} -> closed(conn, seat)
        end

      :seat_link_replaced ->
        Logger.info("[mcp] channel replaced by a newer stream: #{seat}")
        conn
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> loop(conn, seat)
          {:error, _} -> closed(conn, seat)
        end
    end
  end

  defp closed(conn, seat) do
    Logger.info("[mcp] channel closed: #{seat}")
    conn
  end

  # The permission prompt, in the control_request shape Room already tracks.
  # `channel: true` tells Room to answer it down the channel, not the sidecar.
  defp relay_permission_request(user, seat, p) do
    case seat_session(user, seat) do
      nil ->
        Logger.warning("[mcp] permission_request for #{seat}, which has no running session")

      session ->
        Room.mirror_messages(session.id, [
          %{
            "type" => "control_request",
            "request_id" => p["request_id"],
            "channel" => true,
            "request" => %{
              "subtype" => "can_use_tool",
              "tool_name" => p["tool_name"],
              "description" => p["description"],
              "input" => %{"preview" => p["input_preview"]}
            }
          }
        ])
    end
  end

  @doc false
  def seat_session(user, seat) do
    user.id
    |> Sessions.list_sessions_by_title(seat)
    |> Enum.find(&(&1.status == :running))
  end

  defp session_header(user, seat), do: "cv-#{user.id}-" <> Base.url_encode64(seat, padding: false)
  defp rpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end
