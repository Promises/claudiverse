defmodule ClaudiverseServerWeb.UserSocket do
  use Phoenix.Socket

  channel "session:*", ClaudiverseServerWeb.SessionChannel
  channel "operator:human_requests", ClaudiverseServerWeb.OperatorChannel
  channel "operator:events", ClaudiverseServerWeb.OperatorChannel
  channel "host:*", ClaudiverseServerWeb.HostChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    case ClaudiverseServer.Accounts.fetch_api_token(token) do
      {:ok, user, context} ->
        # The address this socket comes from: a host agent's says where its
        # machine is, and a seat's which machine it runs on (Hosts.host_at/2).
        peer = ClaudiverseServer.Hosts.peer_ip(get_in(connect_info, [:peer_data, :address]))
        {:ok, socket |> assign(:current_user, user) |> assign(:token_context, context) |> assign(:peer_ip, peer)}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @doc "A host agent's socket: it may join only its own host:<name> topic."
  def host_token?(socket), do: String.starts_with?(socket.assigns[:token_context] || "", "host:")

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
