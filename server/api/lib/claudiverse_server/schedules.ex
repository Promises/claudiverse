defmodule ClaudiverseServer.Schedules do
  @moduledoc """
  Scheduled prompts: a cron, in an IANA zone, that delivers a stored prompt to
  a seat by title. Kept in the database, so a schedule outlives seat restarts,
  compactions, reboots and server deploys (Claude Code's own CronCreate lives
  in one session and expires after 7 days).

  The Scheduler ticks every 30 s and calls `fire_due/1`. A schedule whose
  `next_fire_at` has passed fires once: a run row is written and
  `next_fire_at` advances to the next time AFTER now, in one transaction.
  After downtime that is still one run, marked `late`, with the original
  `due_at`; the occurrences missed in between are skipped, never piled up.

  Delivery is a user prompt to the seat, reject-busy like a ping:
  - the seat is idle: delivered now (`delivered`);
  - it is busy: `queued`, and delivered when it next goes idle;
  - no seat with that title is running: `waiting_for_seat`, delivered when
    one registers (its inbox poll or its sidecar's join).
  A run still pending when its schedule fires again is `superseded`, so at
  most one prompt per schedule is ever pending.

  The prompt is delivered byte-for-byte after one header line:

      [claudiverse] scheduled prompt "weekly-review" (due Sun 2026-10-18 12:00 CEST (Europe/Oslo)):
      <prompt>

  and a late run says so: `(due …, LATE: fired … after downtime)`.
  """
  import Ecto.Query

  alias ClaudiverseServer.{Repo, Sessions}
  alias ClaudiverseServer.Sessions.Room
  alias ClaudiverseServer.Schedules.{Cron, Run, Schedule}

  # Fired this long after its due time, a run is late: the server was down or
  # a tick was held up. Normal ticks fire within 30 s.
  @late_after_s 90

  # --- schedules -------------------------------------------------------------

  @doc "The user's schedules, by name; `target:` keeps one seat's."
  def list(user_id, opts \\ []) do
    Schedule
    |> where(user_id: ^user_id)
    |> then(fn q -> if t = opts[:target], do: where(q, target_title: ^t), else: q end)
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "One of the user's schedules, by id or by name."
  def get(user_id, id_or_name) when is_binary(id_or_name) do
    case Integer.parse(id_or_name) do
      {id, ""} -> Repo.get_by(Schedule, user_id: user_id, id: id)
      _ -> Repo.get_by(Schedule, user_id: user_id, name: id_or_name)
    end
  end

  def get(user_id, id) when is_integer(id), do: Repo.get_by(Schedule, user_id: user_id, id: id)

  @doc "A new schedule; `next_fire_at` is the first time after `now`."
  def create(user_id, attrs, created_by, now \\ DateTime.utc_now()) do
    %Schedule{}
    |> Schedule.changeset(attrs |> stringify() |> Map.merge(%{"user_id" => user_id, "created_by" => created_by}))
    |> put_next_fire(now)
    |> Repo.insert()
  end

  @doc """
  Edit a schedule. A new cron or zone, or a resume, takes its next time from
  `now`: a schedule paused over its due time does not fire late on resume.
  """
  def update(%Schedule{} = schedule, attrs, now \\ DateTime.utc_now()) do
    attrs = Map.drop(stringify(attrs), ~w(user_id created_by))

    schedule
    |> Schedule.changeset(attrs)
    |> then(fn cs ->
      if Enum.any?([:cron, :tz, :enabled], &Ecto.Changeset.changed?(cs, &1)), do: put_next_fire(cs, now), else: cs
    end)
    |> Repo.update()
  end

  def delete(%Schedule{} = schedule), do: Repo.delete(schedule)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp put_next_fire(%{valid?: false} = cs, _now), do: cs

  defp put_next_fire(cs, now) do
    cron = Ecto.Changeset.get_field(cs, :cron)
    tz = Ecto.Changeset.get_field(cs, :tz)
    Ecto.Changeset.put_change(cs, :next_fire_at, Cron.next_after(cron, tz, now))
  end

  @doc "A schedule's runs, newest first."
  def list_runs(%Schedule{id: id}, limit \\ 50) do
    Run
    |> where(schedule_id: ^id)
    |> order_by(desc: :due_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "The sha256 of a prompt, as lowercase hex."
  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # --- firing ----------------------------------------------------------------

  @doc """
  Fire every enabled schedule that is due at `now`, then deliver each new
  run. Returns the runs written.
  """
  def fire_due(now \\ DateTime.utc_now()) do
    Schedule
    |> where([s], s.enabled and not is_nil(s.next_fire_at) and s.next_fire_at <= ^now)
    |> Repo.all()
    |> Enum.map(&fire(&1, now))
  end

  defp fire(%Schedule{} = schedule, now) do
    now = DateTime.truncate(now, :second)
    due = schedule.next_fire_at

    {:ok, run} =
      Repo.transaction(fn ->
        # At most one pending prompt per schedule: this occurrence replaces
        # one still waiting for its seat (or for it to go idle).
        Run
        |> where([r], r.schedule_id == ^schedule.id and r.status in ^Run.pending_statuses())
        |> Repo.update_all(set: [status: "superseded", updated_at: now])

        run =
          Repo.insert!(%Run{
            schedule_id: schedule.id,
            due_at: due,
            fired_at: now,
            late: DateTime.diff(now, due) > @late_after_s,
            status: "waiting_for_seat"
          })

        schedule
        |> Ecto.Changeset.change(next_fire_at: Cron.next_after(schedule.cron, schedule.tz, now), last_fired_at: now)
        |> Repo.update!()

        run
      end)

    attempt(run, schedule, now)
  end

  # --- delivery --------------------------------------------------------------

  @doc """
  Try every pending run again (each tick): a seat that went idle or came back
  without the Scheduler hearing of it still gets its prompt.
  """
  def retry_pending(now \\ DateTime.utc_now()) do
    pending_query()
    |> Repo.all()
    |> Enum.map(fn {run, schedule} -> attempt(run, schedule, now) end)
  end

  @doc """
  Deliver what is pending for the seat `title` (the user's whose running
  session `session_id` is). Called when the seat goes idle or is seen alive.
  """
  def deliver_pending(title, session_id, now \\ DateTime.utc_now()) do
    case Sessions.get_session(session_id) do
      %{user_id: user_id, title: ^title} ->
        pending_query()
        |> where([_r, s], s.user_id == ^user_id and s.target_title == ^title)
        |> Repo.all()
        |> Enum.map(fn {run, schedule} -> attempt(run, schedule, now) end)

      _ ->
        []
    end
  end

  @doc "The titles with a pending run, and the sessions with a queued one."
  def pending_targets do
    pending_query()
    |> exclude(:select)
    |> select([r, s], {s.target_title, r.session_id})
    |> Repo.all()
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn {title, sid}, {titles, sids} ->
      {MapSet.put(titles, title), if(sid, do: MapSet.put(sids, sid), else: sids)}
    end)
  end

  # A paused schedule's pending run waits for its resume.
  defp pending_query do
    from r in Run,
      join: s in Schedule,
      on: s.id == r.schedule_id,
      where: r.status in ^Run.pending_statuses() and s.enabled,
      order_by: [asc: r.id],
      select: {r, s}
  end

  defp attempt(%Run{} = run, %Schedule{} = schedule, now) do
    now = DateTime.truncate(now, :second)

    {status, session_id, sha} =
      case running_seat(schedule.user_id, schedule.target_title) do
        nil ->
          {"waiting_for_seat", nil, nil}

        seat ->
          case Room.send_message(seat.id, message(schedule, run)) do
            :delivered -> {"delivered", seat.id, sha256(schedule.prompt)}
            {:busy, _hint} -> {"queued", seat.id, nil}
            {:error, _} -> {"waiting_for_seat", nil, nil}
          end
      end

    run
    |> Ecto.Changeset.change(
      status: status,
      session_id: session_id,
      prompt_sha256: sha,
      delivered_at: if(status == "delivered", do: now)
    )
    |> Repo.update!()
  end

  # The seat's live row: running, and not a proxy-only row.
  defp running_seat(user_id, title) do
    user_id
    |> Sessions.list_sessions_by_title(title, status: :running, limit: 5)
    |> Enum.find(&(&1.type != :proxy))
  end

  @doc "The prompt as the seat receives it: one header line, then the prompt exactly."
  def message(%Schedule{} = schedule, %Run{} = run) do
    late =
      if run.late,
        do: ", LATE: fired #{Cron.local_string(run.fired_at, schedule.tz)} after downtime",
        else: ""

    "[claudiverse] scheduled prompt \"#{schedule.name}\" (due #{Cron.local_string(run.due_at, schedule.tz)}#{late}):\n" <>
      schedule.prompt
  end
end
