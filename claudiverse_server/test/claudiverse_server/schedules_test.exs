defmodule ClaudiverseServer.SchedulesTest do
  @moduledoc """
  Scheduled prompts (ClaudiverseServer.Schedules): the next time across a DST
  change, firing once, one late run after downtime, and delivery to a busy
  seat (queued until idle) and an absent one (held until it registers, then
  superseded by the next occurrence). A fake sidecar (the test process) is
  registered on the seat's Room, so delivery is {:forward_to_sidecar, ...}.
  """
  # Not async: the Scheduler and the Room read the database from their own
  # processes, which needs the shared sandbox.
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Schedules
  alias ClaudiverseServer.Schedules.{Cron, Run, Scheduler}
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  @oslo "Europe/Oslo"

  setup do
    on_exit(fn ->
      # The Scheduler keeps the targets of pending runs in memory; left set,
      # a later test's seat would make it read a database this test no longer owns.
      :sys.replace_state(Scheduler, &%{&1 | titles: MapSet.new(), sessions: MapSet.new()})

      for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Sessions.Supervisor), is_pid(pid),
          do: DynamicSupervisor.terminate_child(ClaudiverseServer.Sessions.Supervisor, pid)
    end)

    %{user: user_fixture(), title: "ipsum-admin-#{System.unique_integer([:positive])}"}
  end

  defp schedule(ctx, attrs \\ %{}, now \\ ~U[2026-10-11 09:00:00Z]) do
    attrs = Map.merge(%{name: "weekly-#{System.unique_integer([:positive])}", cron: "0 12 * * 0", tz: @oslo,
                        prompt: "Review the week.", target_title: ctx.title}, attrs)
    {:ok, s} = Schedules.create(ctx.user.id, attrs, ctx.title, now)
    s
  end

  # A seat whose Room has the test process as its sidecar. `idle: false`
  # leaves it busy, as a fresh Room starts.
  defp seat(ctx, idle) do
    seat = session_fixture(ctx.user, %{title: ctx.title})
    {:ok, _} = Supervisor.start_room(seat.id, owner_id: ctx.user.id)
    Room.register_sidecar(seat.id, self())
    if idle, do: go_idle(seat)
    seat
  end

  defp go_idle(seat) do
    Room.mirror_messages(seat.id, [%{"type" => "idle"}])
    Room.get_status(seat.id)
    :sys.get_state(ClaudiverseServer.Notifications.Router)
    :sys.get_state(Scheduler)
  end

  defp runs(s), do: s |> Schedules.list_runs() |> Enum.map(&Map.take(&1, [:status, :late, :due_at, :session_id]))
  defp reload(s), do: Repo.get!(Schedules.Schedule, s.id)

  # --- 1. the next time ------------------------------------------------------

  test "12:00 Oslo stays 12:00 local across both DST changes" do
    # Autumn: Sun 25 Oct 2026 03:00 CEST → 02:00 CET. 12:00 CEST is 10:00Z, 12:00 CET is 11:00Z.
    assert Cron.next_after("0 12 * * 0", @oslo, ~U[2026-10-18 10:00:00Z]) == ~U[2026-10-25 11:00:00Z]
    # Spring: Sun 28 Mar 2027 02:00 CET → 03:00 CEST.
    assert Cron.next_after("0 12 * * 0", @oslo, ~U[2027-03-21 11:00:00Z]) == ~U[2027-03-28 10:00:00Z]
  end

  test "a skipped local time fires just after the gap; a repeated one fires once" do
    # 02:30 does not exist on 28 Mar 2027: the clock goes 02:00 → 03:00 CEST (01:00Z).
    assert Cron.next_after("30 2 * * *", @oslo, ~U[2027-03-27 12:00:00Z]) == ~U[2027-03-28 01:00:00Z]
    # 02:30 happens twice on 25 Oct 2026: first at 00:30Z (CEST); after it, the next is the 26th.
    assert Cron.next_after("30 2 * * *", @oslo, ~U[2026-10-24 12:00:00Z]) == ~U[2026-10-25 00:30:00Z]
    assert Cron.next_after("30 2 * * *", @oslo, ~U[2026-10-25 00:30:00Z]) == ~U[2026-10-26 01:30:00Z]
  end

  # --- 2. firing once ----------------------------------------------------------

  test "a due schedule fires exactly once and advances to its next time", ctx do
    s = schedule(ctx)
    assert s.next_fire_at == ~U[2026-10-11 10:00:00Z]

    assert Scheduler.tick(~U[2026-10-11 09:59:59Z]) == [], "not due yet"
    assert [%Run{late: false, due_at: ~U[2026-10-11 10:00:00Z]}] = Scheduler.tick(~U[2026-10-11 10:00:20Z])
    assert Scheduler.tick(~U[2026-10-11 10:00:50Z]) == [], "the same occurrence fires once"

    s = reload(s)
    assert s.next_fire_at == ~U[2026-10-18 10:00:00Z]
    assert s.last_fired_at == ~U[2026-10-11 10:00:20Z]
    assert length(runs(s)) == 1
  end

  # --- 3. downtime ---------------------------------------------------------------

  test "occurrences missed in downtime give ONE late run, with the original due time", ctx do
    s = schedule(ctx)

    # Down from before the 11th until the 26th: the 11th, 18th and 25th were missed.
    now = ~U[2026-10-26 08:00:00Z]
    assert [%Run{late: true, due_at: ~U[2026-10-11 10:00:00Z], fired_at: ^now}] = Scheduler.tick(now)
    assert Scheduler.tick(now) == []

    assert reload(s).next_fire_at == ~U[2026-11-01 11:00:00Z], "skips to the next future time (CET now)"
    assert [%{late: true}] = runs(s)
  end

  # --- 4 and 5. delivery ---------------------------------------------------------

  test "an idle seat gets the prompt at once, as one header line and the prompt", ctx do
    seat = seat(ctx, true)
    s = schedule(ctx, %{prompt: "Line one.\nLine two."})
    Scheduler.tick(~U[2026-10-11 10:00:05Z])

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content == ~s|[claudiverse] scheduled prompt "#{s.name}" (due Sun 2026-10-11 12:00 CEST (Europe/Oslo)):\nLine one.\nLine two.|
    assert [%Run{status: "delivered", session_id: sid, prompt_sha256: sha}] = Schedules.list_runs(s)
    assert sid == seat.id
    assert sha == Schedules.sha256("Line one.\nLine two.")
  end

  test "a late run says so in its header", ctx do
    seat(ctx, true)
    s = schedule(ctx)
    Scheduler.tick(~U[2026-10-12 06:30:00Z])

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content ==
             ~s|[claudiverse] scheduled prompt "#{s.name}" (due Sun 2026-10-11 12:00 CEST (Europe/Oslo), | <>
               ~s|LATE: fired Mon 2026-10-12 08:30 CEST (Europe/Oslo) after downtime):\nReview the week.|
  end

  test "a busy seat queues the prompt and gets it when it goes idle", ctx do
    seat = seat(ctx, false)
    s = schedule(ctx)
    Scheduler.tick(~U[2026-10-11 10:00:05Z])

    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
    assert [%{status: "queued", session_id: sid}] = runs(s)
    assert sid == seat.id

    go_idle(seat)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ ~s(scheduled prompt "#{s.name}")
    assert [%{status: "delivered"}] = runs(s)
  end

  test "an absent seat's prompt is held until a seat with that title registers", ctx do
    s = schedule(ctx)
    Scheduler.tick(~U[2026-10-11 10:00:05Z])
    assert [%{status: "waiting_for_seat", session_id: nil}] = runs(s)

    # The seat starts and goes idle; then it is seen (its inbox poll or join).
    seat = seat(ctx, true)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
    ClaudiverseServer.Notifications.Router.seat_seen(seat.title, seat.id)
    :sys.get_state(Scheduler)

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ ~s(scheduled prompt "#{s.name}")
    assert [%{status: "delivered"}] = runs(s)
  end

  test "the next occurrence supersedes a held prompt: one pending per schedule", ctx do
    s = schedule(ctx)
    Scheduler.tick(~U[2026-10-11 10:00:05Z])
    Scheduler.tick(~U[2026-10-18 10:00:05Z])

    assert [%{status: "waiting_for_seat", due_at: ~U[2026-10-18 10:00:00Z]}, %{status: "superseded", due_at: ~U[2026-10-11 10:00:00Z]}] =
             runs(s)

    seat = seat(ctx, true)
    ClaudiverseServer.Notifications.Router.seat_seen(seat.title, seat.id)
    :sys.get_state(Scheduler)

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ "due Sun 2026-10-18 12:00"
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end

  test "a paused schedule neither fires nor delivers; resuming does not fire it late", ctx do
    s = schedule(ctx)
    {:ok, s} = Schedules.update(s, %{enabled: false}, ~U[2026-10-11 09:30:00Z])
    assert Scheduler.tick(~U[2026-10-11 10:00:05Z]) == []

    {:ok, s} = Schedules.update(s, %{enabled: true}, ~U[2026-10-12 09:00:00Z])
    assert s.next_fire_at == ~U[2026-10-18 10:00:00Z]
    assert Scheduler.tick(~U[2026-10-12 09:00:30Z]) == []
  end

  # --- the prompt, exactly --------------------------------------------------------

  test "a prompt is stored and delivered byte-for-byte: CRLF, trailing spaces, multi-byte", ctx do
    seat(ctx, true)
    prompt = "  Hei! Æ ø å 🙂\r\nline with trailing spaces   \n\n\ttab\n"
    s = schedule(ctx, %{prompt: prompt})
    assert reload(s).prompt == prompt

    Scheduler.tick(~U[2026-10-11 10:00:05Z])
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    [_header, delivered] = String.split(content, "\n", parts: 2)
    assert delivered == prompt
  end
end
