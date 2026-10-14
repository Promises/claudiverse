defmodule ClaudiverseServerWeb.RunnerController do
  @moduledoc """
  Runner slots and fleets (see ClaudiverseServer.Runners).

  - `POST /api/runners/heartbeat` — a cv-runner's report of its slot:
    %{slot, fleet, state: idle|busy|halted|stopped, host?, lane?, channel?,
      task_source?, model?, seat?, task?, since?}. Sent with the fleet's own
    seat token, like everything else a runner does. A busy slot's seat is
    stamped with the fleet (Sessions.stamp_runner_seat/4).
  - `GET /api/fleets` — per fleet: its runner slots (with a derived status:
    the slot's state, or "missing" when its heartbeats stopped), its running
    seats, and its `members`: the profiles declaring the fleet, each
    %{id, name, role, machine, status, seat} (status as Profiles derives it).
  """
  use ClaudiverseServerWeb, :controller

  import Ecto.Query

  alias ClaudiverseServer.{Profiles, Repo, Runners, Sessions}
  alias ClaudiverseServer.Sessions.Session

  @name ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @optional [host: "host", lane: "lane", channel: "channel", task_source: "task_source", model: "model", seat: "seat", since: "since"]

  def heartbeat(conn, params) do
    with {:ok, report} <- validate(params) do
      user_id = conn.assigns.current_user.id
      :ok = Runners.heartbeat(user_id, report)

      if report.state == "busy" and is_binary(report[:seat]),
        do: Sessions.stamp_runner_seat(user_id, report.seat, report.fleet, report[:host])

      json(conn, %{ok: true})
    else
      {:error, message} -> conn |> put_status(:bad_request) |> json(%{error: message})
    end
  end

  def fleets(conn, _params) do
    user_id = conn.assigns.current_user.id
    runners = Runners.list(user_id)

    seats =
      from(s in Session,
        where: s.user_id == ^user_id and s.status == :running and not is_nil(s.fleet) and s.type != :proxy,
        order_by: [asc: s.title],
        select: %{id: s.id, title: s.title, fleet: s.fleet, origin: s.origin, host: s.host}
      )
      |> Repo.all()

    members =
      for p <- Profiles.with_status(user_id, Profiles.list(user_id)), is_binary(p.fleet),
          do: Map.take(p, [:id, :name, :role, :machine, :status, :seat, :fleet])

    paused = ClaudiverseServer.Fleets.paused(user_id)

    fleets =
      (Enum.map(runners, & &1.fleet) ++ Enum.map(seats, & &1.fleet) ++ Enum.map(members, & &1.fleet) ++ MapSet.to_list(paused))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn fleet ->
        %{
          fleet: fleet,
          # A bulk restart leaves a paused fleet out by default (Restarts).
          paused: MapSet.member?(paused, fleet),
          runners: for(r <- runners, r.fleet == fleet, do: r),
          seats: for(s <- seats, s.fleet == fleet, do: Map.delete(s, :fleet)),
          members: for(m <- members, m.fleet == fleet, do: Map.delete(m, :fleet))
        }
      end)

    json(conn, %{fleets: fleets})
  end

  @doc "PATCH /api/fleets/:fleet {paused}: app or super token. 200 {fleet, paused}."
  def update_fleet(conn, %{"fleet" => fleet} = params) do
    cond do
      not ClaudiverseServer.Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "pausing a fleet is app-only"})

      not is_boolean(params["paused"]) ->
        conn |> put_status(:bad_request) |> json(%{error: "paused must be true or false"})

      ClaudiverseServer.Fleets.set_paused(conn.assigns.current_user.id, fleet, params["paused"]) == :ok ->
        json(conn, %{fleet: fleet, paused: params["paused"]})

      true ->
        conn |> put_status(:bad_request) |> json(%{error: "fleet must be 1-64 of A-Z a-z 0-9 . _ -"})
    end
  end

  defp validate(p) do
    cond do
      not name?(p["slot"]) -> {:error, "slot must be 1-64 of A-Z a-z 0-9 . _ -"}
      not name?(p["fleet"]) -> {:error, "fleet must be 1-64 of A-Z a-z 0-9 . _ -"}
      p["state"] not in Runners.states() -> {:error, "state must be one of #{Enum.join(Runners.states(), ", ")}"}
      p["task"] != nil and not (is_integer(p["task"]) or is_binary(p["task"])) -> {:error, "task must be an id"}
      Enum.any?(@optional, fn {_, k} -> p[k] != nil and not (is_binary(p[k]) and String.length(p[k]) <= 200) end) ->
        {:error, "#{@optional |> Keyword.values() |> Enum.join(", ")} must be text of at most 200 characters"}
      true ->
        optional = for {key, k} <- @optional, is_binary(p[k]), into: %{}, do: {key, p[k]}
        {:ok, Map.merge(optional, %{slot: p["slot"], fleet: p["fleet"], state: p["state"], task: p["task"]})}
    end
  end

  defp name?(v), do: is_binary(v) and Regex.match?(@name, v)
end
