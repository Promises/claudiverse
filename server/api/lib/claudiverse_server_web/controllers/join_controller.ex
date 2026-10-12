defmodule ClaudiverseServerWeb.JoinController do
  @moduledoc """
  One-time join codes (ClaudiverseServer.JoinCodes).

  - `POST /api/join_codes` (app or super token) `{"machine"?}` → 201
    `{code, expires_at, machine, server, command}`: the code, and the exact
    one-line installer command that uses it.
  - `POST /api/join` (no token: the code is the credential) `{"code",
    "machine"?}` → 200 `{machine, seat_token, host_token}`. Failed redeems are
    throttled per address, as sign-ins are.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{Accounts, JoinCodes, LoginThrottle}

  @installer "https://raw.githubusercontent.com/Promises/claudiverse/main/install/install.sh"

  def create(conn, params) do
    machine = blank_nil(params["machine"])

    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "adding a machine is app-only (an app or super token)"})

      true ->
        case JoinCodes.mint(conn.assigns.current_user, machine) do
          {:ok, code, row} ->
            server = server_url(conn)

            conn
            |> put_status(:created)
            |> json(%{
              code: code,
              expires_at: row.expires_at,
              machine: row.machine,
              server: server,
              command: "curl -fsSL #{installer()} | sh -s -- --machine --url #{server} --join #{code}"
            })

          {:error, :bad_machine_name} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "machine must be 1-128 of A-Z a-z 0-9 . _ -"})
        end
    end
  end

  def redeem(conn, params) do
    key = {:join, conn.remote_ip}

    case LoginThrottle.check(key) do
      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{error: "too many failed join codes; try again in #{retry_after} s", retry_after: retry_after})

      :ok ->
        case JoinCodes.redeem(params["code"], blank_nil(params["machine"])) do
          {:ok, %{machine: m, seat_token: seat, host_token: host}} ->
            LoginThrottle.succeeded(key)
            json(conn, %{machine: m, seat_token: seat, host_token: host})

          {:error, :invalid} ->
            LoginThrottle.failed(key)
            conn |> put_status(:forbidden) |> json(%{error: "this join code is unknown, used or expired; make a new one with Add a machine"})

          {:error, :machine_required} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "machine is required: this code was made without a machine name"})

          {:error, :bad_machine_name} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "machine must be 1-128 of A-Z a-z 0-9 . _ -"})
        end
    end
  end

  defp installer, do: Application.get_env(:claudiverse_server, :machine_installer_url, @installer)

  # The address the caller reached this API at: the panel calls it at the URL
  # the browser uses, which is the one a machine on the same network needs.
  defp server_url(conn) do
    port = if {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end

  defp blank_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_nil(_), do: nil
end
