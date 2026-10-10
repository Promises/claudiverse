defmodule ClaudiverseServerWeb.ProfileController do
  @moduledoc """
  Seat profiles (see ClaudiverseServer.Profiles).

  - `GET /api/profiles` — every profile with its derived status; any token
    (a stated choice: seat tokens see folders, acceptable in this private
    project).
  - `GET /api/profiles/:id`

  SUPER TOKEN ONLY (the desktop):
  - `POST /api/profiles` — create; 201 {profile}. Only a rename changes `name`.
  - `PATCH /api/profiles/:id` {revision, ...fields} — `revision` is the one
    the editor read; 409 {profile} with the current one if it has moved on.
    Edits apply at the seat's next start; a running seat shows
    `restart_needed`.
  - `DELETE /api/profiles/:id` — 409 while a seat runs from it.
  - `POST /api/profiles/:id/rename` {name, revision} — see Profiles.rename/4.
    200 {profile, moved} when no seat runs; 202 {profile, moved} when the
    seat was running: it is stopped, renamed and started again on the same
    conversation (the start's outcome arrives as for restart). 409 {error,
    code}: name_taken | stale (with {profile}) | busy (mid-turn) |
    claimed_task (with task_ids). 422 on the name's format. The stop's
    errors as for stop (504 offline).

  APP OR SUPER TOKEN:
  - `POST /api/profiles/:id/start | stop | restart` — relayed to the
    profile's machine. start/restart answer 202; the outcome arrives as a
    "profile" event (op "start") on operator:events and as `last_start`.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{Accounts, Profiles}

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    json(conn, %{profiles: Profiles.with_status(user_id, Profiles.list(user_id))})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, p} <- fetch(conn, id) do
      json(conn, %{profile: listed(conn, p)})
    end
  end

  def create(conn, params) do
    with :ok <- super_only(conn) do
      case Profiles.create(conn.assigns.current_user.id, Map.drop(params, ["revision", "last_start", "id"])) do
        {:ok, p} -> conn |> put_status(:created) |> json(%{profile: listed(conn, p)})
        {:error, cs} -> invalid(conn, cs)
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- super_only(conn),
         {:ok, p} <- fetch(conn, id) do
      cond do
        not is_integer(params["revision"]) ->
          conn |> put_status(:bad_request) |> json(%{error: "revision (the one you read) is required"})

        Map.has_key?(params, "name") and params["name"] != p.name ->
          conn |> put_status(:unprocessable_entity)
          |> json(%{errors: %{name: ["cannot be changed; create a new profile instead"]}})

        true ->
          attrs = Map.take(params, Enum.map(Profiles.Profile.editable_fields(), &to_string/1))

          case Profiles.update(conn.assigns.current_user.id, p, params["revision"], attrs) do
            {:ok, p} -> json(conn, %{profile: listed(conn, p)})
            {:error, :stale} -> conn |> put_status(:conflict) |> json(%{error: "edited since you read it", profile: listed(conn, Profiles.get(p.user_id, p.id))})
            {:error, cs} -> invalid(conn, cs)
          end
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- super_only(conn),
         {:ok, p} <- fetch(conn, id) do
      case Profiles.delete(conn.assigns.current_user.id, p) do
        {:ok, _} -> send_resp(conn, :no_content, "")
        {:error, :running} -> conn |> put_status(:conflict) |> json(%{error: "a seat runs from this profile; stop it first"})
      end
    end
  end

  def rename(conn, %{"id" => id} = params) do
    with :ok <- super_only(conn),
         {:ok, p} <- fetch(conn, id) do
      cond do
        not is_integer(params["revision"]) ->
          conn |> put_status(:bad_request) |> json(%{error: "revision (the one you read) is required"})

        not is_binary(params["name"]) ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{name: ["can't be blank"]}})

        params["name"] == p.name ->
          json(conn, %{profile: listed(conn, p), moved: %{}})

        true ->
          case Profiles.rename(conn.assigns.current_user.id, p, params["revision"], params["name"]) do
            {:ok, p, moved, :stopped} -> json(conn, %{profile: listed(conn, p), moved: moved})
            {:ok, p, moved, :restarted} -> conn |> put_status(:accepted) |> json(%{profile: listed(conn, p), moved: moved})
            {:error, :stale} -> conflict(conn, "stale", "edited since you read it", %{profile: listed(conn, p)})
            {:error, :name_taken, why} -> conflict(conn, "name_taken", why)
            {:error, :busy} -> conflict(conn, "busy", "the seat is mid-turn; rename it once it is idle")
            {:error, :claimed_task, ids} -> conflict(conn, "claimed_task", "the seat holds claimed tasks; a runner tracks them by its title", %{task_ids: ids})
            {:error, %Ecto.Changeset{} = cs} -> name_error(conn, cs)
            other -> failed(conn, p, other)
          end
      end
    end
  end

  defp conflict(conn, code, error, extra \\ %{}),
    do: conn |> put_status(:conflict) |> json(Map.merge(%{error: error, code: code}, extra))

  # A profile holding the name is name_taken, as for a running seat.
  defp name_error(conn, cs) do
    if Enum.any?(cs.errors, fn {f, {msg, _}} -> f == :name and msg =~ "exists" end),
      do: conflict(conn, "name_taken", "a profile with this name exists"),
      else: invalid(conn, cs)
  end

  def start(conn, %{"id" => id}), do: control(conn, id, &Profiles.start/2)
  def restart(conn, %{"id" => id}), do: control(conn, id, &Profiles.restart/2)

  def stop(conn, %{"id" => id}) do
    with :ok <- app_only(conn),
         {:ok, p} <- fetch(conn, id) do
      case Profiles.stop(conn.assigns.current_user.id, p) do
        :ok -> json(conn, %{ok: true})
        other -> failed(conn, p, other)
      end
    end
  end

  defp control(conn, id, f) do
    with :ok <- app_only(conn),
         {:ok, p} <- fetch(conn, id) do
      case f.(conn.assigns.current_user.id, p) do
        :ok -> conn |> put_status(:accepted) |> json(%{profile: listed(conn, Profiles.get(p.user_id, p.id))})
        other -> failed(conn, p, other)
      end
    end
  end

  defp failed(conn, _p, {:error, :running}), do: conn |> put_status(:conflict) |> json(%{error: "already running"})
  defp failed(conn, p, {:error, :offline}), do: conn |> put_status(:gateway_timeout) |> json(%{error: "#{p.machine} is offline"})
  defp failed(conn, p, {:error, :timeout}), do: conn |> put_status(:gateway_timeout) |> json(%{error: "#{p.machine} did not answer"})
  defp failed(conn, _p, {:error, :rate_limited}), do: conn |> put_status(:too_many_requests) |> json(%{error: "one start per 10 s per machine"})
  # The agent's refusal codes, as HTTP (as HostController maps them).
  defp failed(conn, _p, {:error, code, message}) do
    status =
      case code do
        c when c in ["outside_roots", "not_allowed"] -> :forbidden
        "not_found" -> :not_found
        "bad_request" -> :bad_request
        "limit" -> :too_many_requests
        _ -> :bad_gateway
      end

    conn |> put_status(status) |> json(%{error: message, code: code})
  end

  defp listed(conn, p) do
    [listed] = Profiles.with_status(conn.assigns.current_user.id, [p])
    listed
  end

  defp fetch(conn, id) do
    case Profiles.get(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
      p -> {:ok, p}
    end
  end

  defp super_only(conn) do
    if Accounts.super_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: conn |> put_status(:forbidden) |> json(%{error: "editing profiles needs the super (desktop) token"})
  end

  # Every seat carries the shared "api" token, so only the app's own token may
  # start or stop seats.
  defp app_only(conn) do
    if Accounts.app_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: conn |> put_status(:forbidden) |> json(%{error: "starting and stopping seats is app-only"})
  end

  defp invalid(conn, cs) do
    errors = Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)

    conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
  end
end
