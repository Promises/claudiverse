defmodule ClaudiverseServerWeb.OperatorChannel do
  @moduledoc """
  The operator's app listens here. Scoped to the socket's own user; a host
  agent's token cannot join.

  `operator:human_requests` — seats asking for a human:
    "human_request"           the request object (also re-sent when updated)
    "human_request_resolved"  %{"id", "session_id"}

  `operator:events` — operator-facing events in general:
    "host_spawn"              %{"spawn_id", "host", "title", "ok", "error", "op", ...}
    "host"                    %{"name", "online", "last_seen_at"}: a machine's
                              agent joined or left; refetch GET /api/hosts
    "runner"                  one runner slot as GET /api/fleets lists it, on
                              any change of its status, seat or task
    "pool"                    %{"change" => preferred|upgrade|degrade|cooling,
                              "by", "at", "current_id", "preferred_id"}: refetch
                              GET /api/anthropic_auths
    "profile"                 %{"op" => created|updated|deleted|start|stopped,
                              "profile" => as GET /api/profiles lists it}
  """
  use Phoenix.Channel

  alias ClaudiverseServer.{Hosts, HumanRequests}

  @impl true
  def join(topic, _params, socket) do
    user_id = socket.assigns.current_user.id

    cond do
      ClaudiverseServerWeb.UserSocket.host_token?(socket) ->
        {:error, %{reason: "host tokens cannot join operator topics"}}

      topic == "operator:human_requests" ->
        Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, HumanRequests.topic(user_id))
        {:ok, socket}

      topic == "operator:events" ->
        Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(user_id))
        Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, ClaudiverseServer.AnthropicAuths.pool_topic())
        {:ok, socket}

      true ->
        {:error, %{reason: "unknown topic"}}
    end
  end

  @events ~w(human_request human_request_resolved host_spawn host runner profile pool)

  @impl true
  def handle_info({event, payload}, socket) when event in @events do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
