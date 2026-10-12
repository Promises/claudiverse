defmodule ClaudiverseServerWeb.Plugs.Auth do
  import Plug.Conn
  import Phoenix.Controller

  alias ClaudiverseServer.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user, context} <- Accounts.fetch_api_token(token),
         # A host agent's token is for its own channel only (HostChannel).
         false <- String.starts_with?(context, "host:") do
      conn
      |> assign(:current_user, user)
      |> assign(:api_token, token)
      # "api", "app" or "super" — see Accounts.app_powers?/1 and super_powers?/1.
      |> assign(:token_context, context)
      |> assign(:client_identity, client_identity(conn))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})
        |> halt()
    end
  end

  @doc """
  Which SEAT sent this request, from the `X-Claudiverse-Client` header.

  ⭐ PARSED HERE, ONCE. The API token is shared by every seat, so `current_user`
  identifies the fleet, not the caller. This is the only thing that distinguishes
  them, and it is read in the plug so every controller has it without per-endpoint
  plumbing — the same reason `current_user` lives here.

  Shape: `title=<urlencoded>; id=<urlencoded>` — see SidecarClient.clientIdentity().
  `id` is empty on a seat's FIRST request: the startup lease runs before Claude's
  session hook fires. That is expected, not a malformed header.

  🔴 ALWAYS RETURNS A MAP, NEVER RAISES. This runs on the authentication path for
  every API call. A malformed or absent header must degrade to "unidentified
  seat" — losing the identity is a gap in a diagnostic, whereas raising here
  would take down the lease endpoint and with it the whole fleet's ability to get
  credentials. The failure has to be smaller than the thing it is diagnosing.
  """
  def client_identity(conn) do
    case get_req_header(conn, "x-claudiverse-client") do
      [raw | _] when is_binary(raw) -> parse_identity(raw)
      _ -> %{title: nil, claude_session_id: nil, instance_id: nil}
    end
  end

  defp parse_identity(raw) do
    fields =
      raw
      |> String.split(";")
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> Map.put(acc, k, v)
          _ -> acc
        end
      end)

    %{
      title: decode(Map.get(fields, "title")),
      claude_session_id: decode(Map.get(fields, "id")),
      # The join key. Everything else here is descriptive.
      instance_id: decode(Map.get(fields, "instance"))
    }
  end

  # Values are percent-encoded by the client so a title cannot smuggle the "; "
  # separator and forge a second field. Decode failures fall back to nil rather
  # than to the raw string: a half-decoded title is a wrong answer that looks
  # like a right one, and an absent seat name is at least honest.
  defp decode(nil), do: nil
  defp decode(""), do: nil

  defp decode(value) do
    URI.decode(value)
  rescue
    _ -> nil
  end
end
