defmodule ClaudiverseServerWeb.ScheduleController do
  @moduledoc """
  Scheduled prompts (ClaudiverseServer.Schedules), under /api/schedules.

  Who may do what:
  - an app or super token: any of the user's schedules;
  - a seat (the shared api token, naming itself with `self`): only schedules
    whose target is its own title. A seat cannot schedule for another seat.

  🔴 Every seat carries the same api token, so `self` is what the seat SAYS it
  is, as for cv_subscribe and the forum. The rule stops a seat from
  scheduling into another by mistake; it is not a boundary against a seat
  that lies about its title.

  Every refusal is a 4xx with an `error` that says why, so a tool can show it.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{Accounts, Schedules}
  alias ClaudiverseServer.Schedules.{Cron, Run, Schedule}

  @preview_chars 120

  # GET /api/schedules?self=&target=&full=
  def index(conn, params) do
    with {:ok, caller} <- caller(conn, params),
         {:ok, target} <- list_target(caller, blank_nil(params["target"])) do
      full = params["full"] in [true, "true", "1"]
      schedules = Schedules.list(conn.assigns.current_user.id, target: target)
      json(conn, %{schedules: Enum.map(schedules, &listed(&1, full))})
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # GET /api/schedules/:id — the full prompt, always.
  def show(conn, %{"id" => id} = params) do
    with {:ok, caller} <- caller(conn, params),
         {:ok, schedule} <- fetch(conn, caller, id) do
      json(conn, %{schedule: listed(schedule, true)})
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # POST /api/schedules  %{self, name, cron, tz, prompt, target}
  def create(conn, params) do
    with {:ok, caller} <- caller(conn, params),
         {:ok, target} <- create_target(caller, blank_nil(params["target"])) do
      attrs = params |> Map.take(~w(name cron tz prompt enabled)) |> Map.put("target_title", target)

      case Schedules.create(conn.assigns.current_user.id, attrs, created_by(caller)) do
        {:ok, schedule} ->
          conn |> put_status(:created) |> json(%{schedule: listed(schedule, false)})

        {:error, cs} ->
          invalid(conn, cs)
      end
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # PATCH /api/schedules/:id  %{self, enabled, name, cron, tz, prompt, target}
  def update(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.take(~w(name cron tz prompt enabled target))
      |> then(fn a -> if Map.has_key?(a, "target"), do: Map.put(Map.delete(a, "target"), "target_title", a["target"]), else: a end)

    with {:ok, caller} <- caller(conn, params),
         {:ok, schedule} <- fetch(conn, caller, id),
         :ok <- may_target(caller, Map.get(attrs, "target_title", schedule.target_title)) do
      case Schedules.update(schedule, attrs) do
        {:ok, schedule} ->
          json(conn, %{schedule: listed(schedule, false)})

        {:error, cs} ->
          invalid(conn, cs)
      end
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # DELETE /api/schedules/:id?self=  (its runs go with it)
  def delete(conn, %{"id" => id} = params) do
    with {:ok, caller} <- caller(conn, params),
         {:ok, schedule} <- fetch(conn, caller, id) do
      {:ok, _} = Schedules.delete(schedule)
      json(conn, %{deleted: %{id: schedule.id, name: schedule.name}})
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # GET /api/schedules/:id/runs?self=&limit=
  def runs(conn, %{"id" => id} = params) do
    limit = with {n, ""} <- Integer.parse(to_string(params["limit"] || "50")), do: min(max(n, 1), 500), else: (_ -> 50)

    with {:ok, caller} <- caller(conn, params),
         {:ok, schedule} <- fetch(conn, caller, id) do
      json(conn, %{schedule: listed(schedule, false), runs: Enum.map(Schedules.list_runs(schedule, limit), &run/1)})
    else
      {:refuse, status, error} -> refuse(conn, status, error)
    end
  end

  # --- who is asking --------------------------------------------------------

  defp caller(conn, params) do
    cond do
      Accounts.app_powers?(conn.assigns[:token_context]) -> {:ok, :app}
      is_binary(params["self"]) and params["self"] != "" -> {:ok, {:seat, params["self"]}}
      true -> {:refuse, :bad_request, "which seat? pass self (your seat title); only an app token may omit it"}
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v

  defp created_by(:app), do: "app"
  defp created_by({:seat, title}), do: title

  defp may_target(:app, _target), do: :ok
  defp may_target({:seat, title}, title), do: :ok

  defp may_target({:seat, title}, target),
    do: {:refuse, :forbidden, "a seat may only schedule prompts for itself: you are #{title}, the target is #{target}"}

  defp list_target(:app, target), do: {:ok, target}
  defp list_target({:seat, title}, nil), do: {:ok, title}

  defp list_target({:seat, _} = seat, target) do
    with :ok <- may_target(seat, target), do: {:ok, target}
  end

  defp create_target(:app, target) when is_binary(target) and target != "", do: {:ok, target}
  defp create_target(:app, _), do: {:refuse, :unprocessable_entity, "target: an app token must name the seat (target)"}
  defp create_target({:seat, title}, nil), do: {:ok, title}

  defp create_target({:seat, _} = seat, target) do
    with :ok <- may_target(seat, target), do: {:ok, target}
  end

  defp fetch(conn, caller, id) do
    case Schedules.get(conn.assigns.current_user.id, id) do
      nil ->
        {:refuse, :not_found, "no schedule #{id}"}

      %Schedule{} = s ->
        case may_target(caller, s.target_title) do
          :ok -> {:ok, s}
          {:refuse, status, _} -> {:refuse, status, "schedule #{s.name} targets #{s.target_title}; a seat may only manage its own"}
        end
    end
  end

  # --- answers --------------------------------------------------------------

  defp refuse(conn, status, error), do: conn |> put_status(status) |> json(%{error: error})

  defp invalid(conn, cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    error = Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    conn |> put_status(:unprocessable_entity) |> json(%{error: error, errors: errors})
  end

  defp listed(%Schedule{} = s, full) do
    %{
      id: s.id,
      name: s.name,
      target: s.target_title,
      cron: s.cron,
      tz: s.tz,
      enabled: s.enabled,
      created_by: s.created_by,
      next_fire_at: s.next_fire_at,
      next_fire_local: s.next_fire_at && Cron.local_string(s.next_fire_at, s.tz),
      last_fired_at: s.last_fired_at,
      prompt_chars: s.prompt |> String.codepoints() |> length(),
      prompt_bytes: byte_size(s.prompt),
      prompt_sha256: Schedules.sha256(s.prompt),
      prompt_preview: s.prompt |> String.codepoints() |> Enum.take(@preview_chars) |> Enum.join()
    }
    |> then(fn m -> if full, do: Map.put(m, :prompt, s.prompt), else: m end)
  end

  defp run(%Run{} = r) do
    Map.take(r, [:id, :due_at, :fired_at, :delivered_at, :late, :status, :session_id, :prompt_sha256])
  end
end
