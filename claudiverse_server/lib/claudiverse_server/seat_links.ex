defmodule ClaudiverseServer.SeatLinks do
  @moduledoc """
  The two live links a seat can hold open to the server without any patch in
  its binary, keyed by `{user_id, seat_title}`:

  - **channel** — the seat's MCP channel stream (`GET /api/mcp/seat/:seat`).
    Prompts (`cv_send`) and permission decisions are pushed down it as
    `notifications/claude/channel` and `notifications/claude/channel/permission`.
    Replaces patch 003, and answers permission prompts as well.
  - **question** — a PreToolUse hook request for `AskUserQuestion`, held open
    until `cv_answer`/`cv_decline` (`POST /api/hooks/seat/:seat/pretooluse`).
    Replaces patch 007.
  - **inbox** — a long poll from the seat's `asyncRewake` hook
    (`GET /api/seats/:seat/inbox`), answered with the next prompt. Replaces
    003's delivery where channels are unavailable. See SeatInbox.

  Both are processes registered in a unique Registry. A new link for a seat
  REPLACES the old one — a reconnected stream or a new question is always the
  live one, and the stale process is told to stop.

  `Room` asks here first and falls back to the sidecar when a seat has no link,
  so seats running the patched binary behave exactly as before.
  """

  @registry ClaudiverseServer.SeatLinks.Registry

  def child_spec(_), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc "Register the calling process as `seat`'s `kind` link, replacing any older one."
  def register(kind, user_id, seat) when kind in [:channel, :question, :inbox] do
    key = {kind, user_id, seat}

    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        :ok

      # Bandit serves later requests on a keep-alive connection from the same
      # process, so the "older" link may be this very process: keep it.
      {:error, {:already_registered, old}} when old == self() ->
        :ok

      # Tell the old link to finish; it RELEASES the key when its request
      # ends (it may live on, serving its connection's next request). Only a
      # link that does not let go within 2 s is killed.
      {:error, {:already_registered, old}} ->
        send(old, :seat_link_replaced)
        await_release(key, old, 100)
        register(kind, user_id, seat)
    end
  end

  defp await_release(key, old, 0) do
    if Registry.lookup(@registry, key) == [{old, nil}], do: Process.exit(old, :kill)
    Process.sleep(10)
  end

  defp await_release(key, old, n) do
    case Registry.lookup(@registry, key) do
      [{^old, _}] -> Process.sleep(20) && await_release(key, old, n - 1)
      _ -> :ok
    end
  end

  @doc """
  Drop the calling process's `kind` link for `seat`. Called when a request
  ends: the process may live on serving the next request on the same
  connection, and must not keep receiving this seat's deliveries.
  """
  def unregister(kind, user_id, seat), do: Registry.unregister(@registry, {kind, user_id, seat})

  @doc "Send `message` to `seat`'s `kind` link. `:ok`, or `:no_link`."
  def deliver(kind, user_id, seat, message) do
    case Registry.lookup(@registry, {kind, user_id, seat}) do
      [{pid, _}] ->
        send(pid, message)
        :ok

      [] ->
        :no_link
    end
  end

  def linked?(kind, user_id, seat), do: Registry.lookup(@registry, {kind, user_id, seat}) != []

  @doc """
  A held PermissionRequest hook, keyed by the request id the server minted
  for it (several can be open at once, e.g. parallel subagents), so not
  replace-per-seat like the other kinds.
  """
  def register_request(request_id) do
    {:ok, _} = Registry.register(@registry, {:permission, request_id}, nil)
    :ok
  end

  def unregister_request(request_id), do: Registry.unregister(@registry, {:permission, request_id})

  @doc "Send `message` to the held hook for `request_id`. `:ok`, or `:no_link`."
  def deliver_request(request_id, message) do
    case Registry.lookup(@registry, {:permission, request_id}) do
      [{pid, _}] -> send(pid, message) && :ok
      [] -> :no_link
    end
  end

  @doc "The channel notification that delivers `content` as a prompt."
  def prompt(content) do
    {:channel_push,
     %{"jsonrpc" => "2.0", "method" => "notifications/claude/channel",
       "params" => %{"content" => content, "meta" => %{"from" => "claudiverse"}}}}
  end

  @doc "The channel notification that answers a relayed permission prompt."
  def permission(request_id, behavior) when behavior in ["allow", "deny"] do
    {:channel_push,
     %{"jsonrpc" => "2.0", "method" => "notifications/claude/channel/permission",
       "params" => %{"request_id" => request_id, "behavior" => behavior}}}
  end
end
