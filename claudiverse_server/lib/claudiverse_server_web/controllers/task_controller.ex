defmodule ClaudiverseServerWeb.TaskController do
  @moduledoc """
  Component E's HTTP surface.

  Note what is NOT here: an endpoint that creates a task in a state a runner
  cannot see. `POST /api/tasks` takes `ready: true` to publish immediately, or
  leaves it DRAFT deliberately — there is no way to produce the invisible-task
  failure by omission.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Tasks

  def create(conn, params) do
    attrs = Map.put_new(params, "state", if(params["ready"] == true, do: "READY", else: "DRAFT"))

    case Tasks.create(Map.drop(attrs, ["ready"])) do
      {:ok, t} -> json(conn, %{ok: true, task: task_json(t)})
      {:error, cs} -> unprocessable(conn, cs)
    end
  end

  def index(conn, params) do
    opts =
      [:fleet, :lane, :state, :claimed_by]
      |> Enum.map(&{&1, params[to_string(&1)]})
      |> Keyword.put(:limit, to_int(params["limit"] || 50))

    json(conn, %{ok: true, tasks: Tasks.list(opts) |> Enum.map(&task_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case Tasks.get(to_int(id)) do
      nil ->
        not_found(conn, id)

      t ->
        json(conn, %{
          ok: true,
          task: task_json(t),
          events: Tasks.events(t.id) |> Enum.map(&event_json/1),
          blocked_by: Tasks.unmet_blockers(t.id) |> Enum.map(& &1.id)
        })
    end
  end

  def update(conn, %{"id" => id} = params) do
    actor = params["actor"] || params["by"]

    case Tasks.update_draft(id, params, actor) do
      {:ok, task} ->
        json(conn, %{ok: true, task: task_json(task)})

      {:error, :no_such_task} ->
        conn |> put_status(404) |> json(%{error: "no such task"})

      {:error, :nothing_to_update} ->
        conn
        |> put_status(422)
        |> json(%{error: "no editable field given", editable: ~w(title body_md priority lane vm_required)})

      {:error, {:not_editable, state}} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "only an UNCLAIMED task can be edited (DRAFT or READY)",
          state: state,
          hint: "a claimed brief must not change under the worker reading it — retire it with POST /tasks/:id/supersede and author a replacement"
        })

      {:error, cs} ->
        conn |> put_status(422) |> json(%{error: inspect(cs)})
    end
  end

  def ready(conn, %{"id" => id} = p) do
    case Tasks.make_ready(to_int(id), p["actor"]) do
      {:ok, t} ->
        json(conn, %{ok: true, task: task_json(t)})

      {:error, :actor_required} ->
        actor_required(conn)

      {:error, {:blocked_by, ids}} ->
        # 409: the task is well-formed, the WORLD is not ready for it.
        conn
        |> put_status(:conflict)
        |> json(%{ok: false, error: "blocked by unmet BLOCKS dependencies", blocked_by: ids})

      {:error, :no_such_task} ->
        not_found(conn, id)

      {:error, cs} ->
        unprocessable(conn, cs)
    end
  end

  def claim(conn, %{"fleet" => fleet, "lane" => lane, "worker" => worker} = p) do
    case Tasks.claim(fleet, lane, worker,
           vm_busy: p["vm_busy"] == true,
           exclude: exclude_ids(p["exclude"])
         ) do
      {:ok, t} ->
        json(conn, %{ok: true, task: task_json(t)})

      {:error, :none_ready} ->
        # ⚠️ 200, not 404. An empty queue is a normal poll result, not an error,
        # and a runner must be able to tell "nothing to do" from "the call
        # failed" without parsing an error body.
        json(conn, %{ok: true, task: nil, reason: "none_ready"})

      {:error, :lost_race} ->
        json(conn, %{ok: true, task: nil, reason: "lost_race"})
    end
  end

  def start(conn, %{"id" => id, "worker" => w}) do
    respond(conn, Tasks.start(to_int(id), w), id)
  end

  def progress(conn, %{"id" => id, "worker" => w} = p) do
    case Tasks.progress(to_int(id), w, p["detail"]) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :no_such_task} -> not_found(conn, id)
      {:error, cs} -> unprocessable(conn, cs)
    end
  end

  def complete(conn, %{"id" => id, "worker" => w} = p) do
    held = if p["held_task_id"], do: to_int(p["held_task_id"])

    case Tasks.complete(to_int(id), w, held_task_id: held) do
      {:ok, %{task: t, stranded: s}} ->
        json(conn, %{
          ok: true,
          task: task_json(t),
          stranded: s && task_json(s),
          note:
            s &&
              "protocol violation: worker held ##{s.id} but completed ##{t.id}. " <>
                "The held task was released back to READY and the slot is free."
        })

      {:error, :no_such_task} ->
        not_found(conn, id)

      {:error, cs} ->
        unprocessable(conn, cs)
    end
  end

  def release(conn, %{"id" => id, "worker" => w} = p) do
    respond(conn, Tasks.release(to_int(id), w, p["reason"]), id)
  end

  def add_dep(conn, %{"id" => id, "depends_on" => dep} = p) do
    case Tasks.add_dep(to_int(id), to_int(dep), p["kind"] || "BLOCKS", p["actor"]) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :actor_required} -> actor_required(conn)
      {:error, cs} -> unprocessable(conn, cs)
    end
  end

  defp actor_required(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      ok: false,
      error: "actor is required",
      why: "publishing a task or adding a BLOCKS edge changes what workers may claim; an anonymous one leaves no one to ask"
    })
  end

  def supersede(conn, %{"id" => id} = p) do
    case Tasks.supersede(to_int(id), to_int(p["superseded_by"]), p["actor"]) do
      {:ok, t} ->
        json(conn, %{ok: true, task: task_json(t)})

      {:error, :actor_required} ->
        actor_required(conn)

      {:error, :superseded_by_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          ok: false,
          error: "superseded_by is required",
          why: "a retirement with no replacement named cannot be told apart from an abandonment"
        })

      {:error, :no_such_task} ->
        not_found(conn, id)

      {:error, cs} ->
        unprocessable(conn, cs)
    end
  end

  def chain(conn, %{"id" => id}) do
    json(conn, %{ok: true, chain: Tasks.validation_chain(to_int(id)) |> Enum.map(&task_json/1)})
  end

  @doc """
  The watcher sweep as a query.

  `live_lanes` and `live_workers` are REQUIRED parameters, not inferred. The
  server cannot see tmux, and a claimed task leaves the ready set — so a
  fed-and-working lane and a starving one produce the identical zero. Depth is
  only interpretable next to consumer liveness.
  """
  def health(conn, %{"fleet" => fleet} = p) do
    live_lanes = List.wrap(p["live_lanes"] || [])
    live_workers = List.wrap(p["live_workers"] || [])

    starved = Tasks.starving_lanes(fleet, live_lanes)
    stranded = Tasks.stranded_tasks(fleet, live_workers)
    stalled = Tasks.stalled_tasks(fleet, to_int(p["stall_minutes"] || 45))

    json(conn, %{
      ok: true,
      starved_lanes: starved,
      stranded: Enum.map(stranded, &task_json/1),
      stalled: Enum.map(stalled, &task_json/1),
      note:
        "starved/stranded are computed against the live_lanes and live_workers you supplied; " <>
          "stalled samples SILENCE and is advisory — confirm with CPU-tree sampling before acting"
    })
  end

  defp respond(conn, {:ok, t}, _id), do: json(conn, %{ok: true, task: task_json(t)})
  defp respond(conn, {:error, :no_such_task}, id), do: not_found(conn, id)
  defp respond(conn, {:error, cs}, _id), do: unprocessable(conn, cs)

  defp not_found(conn, id),
    do: conn |> put_status(:not_found) |> json(%{ok: false, error: "no task #{id}"})

  defp unprocessable(conn, cs),
    do: conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})

  # ⛔ :body_md IS LOAD-BEARING — it is the task itself, not metadata.
  #
  # It was omitted here, so `cv-runner` (which reads `t.body_md || ""`) built
  # every worker prompt from the TITLE ALONE. MEASURED 2026-09-11 on the live
  # worker running #16: the injected prompt was the title, three blank lines,
  # then the generic finish instructions. Zero occurrences of the addresses, the
  # governing procedure, or the acceptance criteria.
  #
  # Nothing errored. A worker handed only a title improvises something
  # plausible, and plausible-but-ungoverned output is indistinguishable from
  # real work until someone checks it against a rule the worker never saw.
  defp task_json(t) do
    Map.take(t, [
      :id, :fleet, :lane, :title, :body_md, :state, :priority, :claimed_by, :claimed_at,
      :started_at, :completed_at, :validates_task_id, :superseded_by,
      :vm_required, :created_by, :inserted_at
    ])
  end

  defp event_json(e), do: Map.take(e, [:id, :at, :kind, :actor, :detail])

  # Only well-formed ids; anything else is dropped, not coerced. to_int/1 would
  # turn "12abc" into 12 — a guess about which task the caller meant, and
  # excluding the wrong task is silent. The runner sends integers.
  defp exclude_ids(ids) when is_list(ids) do
    Enum.flat_map(ids, fn
      n when is_integer(n) -> [n]
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> [n]
          _ -> []
        end
      _ -> []
    end)
  end

  defp exclude_ids(_), do: []

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp errors(cs),
    do:
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)
end
