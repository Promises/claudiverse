defmodule ClaudiverseServer.SessionListOrderingTest do
  @moduledoc """
  The session list is ordered by LAST ACTIVITY, and must stay cheap.

  🔴 The first implementation was correct and unusable. It LEFT-joined

      (SELECT session_id, max(inserted_at) FROM messages GROUP BY session_id)

  which groups the entire messages table before the LIMIT can apply. Measured
  against the live database 2026-09-16: `limit=3` 17.8s, `limit=200` 34s — the
  web panel sat on "Loading…" for half a minute and MCP clients timed out.

  These tests pin BOTH halves: the ordering it produces, and the shape of the
  query that produces it. A correctness-only test passes just as happily on the
  form that took 34 seconds.
  """
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Repo, Sessions}

  # Messages are timestamped by the database at insert, so every row in a test
  # lands in the same second and cannot discriminate an ordering. Written
  # directly with explicit times instead.
  defp message_at(session, sequence, naive) do
    {1, nil} =
      Repo.insert_all("messages", [
        %{
          type: "assistant",
          payload: Jason.encode!(%{}),
          sequence: sequence,
          session_id: session.id,
          inserted_at: naive
        }
      ])

    :ok
  end

  defp at(iso), do: NaiveDateTime.from_iso8601!(iso) |> NaiveDateTime.truncate(:second)

  defp created_at(session, iso) do
    {1, nil} =
      Repo.update_all(
        from(s in "sessions", where: s.id == ^session.id),
        set: [inserted_at: at(iso), updated_at: at(iso)]
      )

    Sessions.get_session!(session.id)
  end

  test "a long-lived seat that just worked outranks a newer idle one" do
    {user, _token} = user_with_token()

    old_and_busy = session_fixture(user, %{title: "old-and-busy"}) |> created_at("2026-09-01 08:00:00")
    new_and_quiet = session_fixture(user, %{title: "new-and-quiet"}) |> created_at("2026-09-15 08:00:00")

    message_at(old_and_busy, 1, at("2026-09-16 09:00:00"))
    message_at(new_and_quiet, 1, at("2026-09-15 08:05:00"))

    titles = Sessions.list_sessions(user.id) |> Enum.map(& &1.title)

    assert titles == ["old-and-busy", "new-and-quiet"],
           "ordering by creation would have put the newer, idle seat first"
  end

  test "the newest message wins, not the first one" do
    {user, _token} = user_with_token()

    a = session_fixture(user, %{title: "a"}) |> created_at("2026-09-01 08:00:00")
    b = session_fixture(user, %{title: "b"}) |> created_at("2026-09-01 08:00:00")

    # `a` started talking first but `b` spoke last.
    message_at(a, 1, at("2026-09-16 09:00:00"))
    message_at(a, 2, at("2026-09-16 09:01:00"))
    message_at(b, 1, at("2026-09-16 09:02:00"))

    assert Sessions.list_sessions(user.id) |> Enum.map(& &1.title) == ["b", "a"]
  end

  test "a session with no messages yet sorts by its creation time, not last" do
    {user, _token} = user_with_token()

    spoken = session_fixture(user, %{title: "spoken"}) |> created_at("2026-09-01 08:00:00")
    _silent = session_fixture(user, %{title: "just-started"}) |> created_at("2026-09-16 10:00:00")

    message_at(spoken, 1, at("2026-09-16 09:00:00"))

    sessions = Sessions.list_sessions(user.id)

    assert Enum.map(sessions, & &1.title) == ["just-started", "spoken"],
           "a seat that has said nothing yet must not be dropped or sorted last"

    assert Enum.find(sessions, &(&1.title == "just-started")).last_activity_at ==
             at("2026-09-16 10:00:00")
  end

  test "running sessions still come before stopped ones, however stale" do
    {user, _token} = user_with_token()

    stopped = session_fixture(user, %{title: "stopped-but-recent", status: :stopped})
    running = session_fixture(user, %{title: "running-but-quiet"}) |> created_at("2026-09-01 08:00:00")

    message_at(stopped, 1, at("2026-09-16 10:00:00"))
    message_at(running, 1, at("2026-09-01 08:00:00"))

    assert Sessions.list_sessions(user.id, status: :all) |> Enum.map(& &1.title) ==
             ["running-but-quiet", "stopped-but-recent"]
  end

  # 🔴 THE ASSUMPTION THAT DOES NOT HOLD. Reading inserted_at off the row with
  # the highest `sequence` is only equivalent to max(inserted_at) if sequence
  # rises with insertion time. It is seeded per ROOM from max(sequence)+1 at
  # init (Sessions.next_sequence/1) and then incremented IN MEMORY, and
  # create_message's result is never checked — so ties and gaps are reachable,
  # and a tie makes "ORDER BY sequence DESC LIMIT 1" pick an arbitrary row among
  # the tied ones. Observed live 2026-09-17: session "testme" answered a message
  # (user -> assistant -> turn_complete in its transcript) while the list kept
  # reporting last_activity_at from 90 seconds earlier.
  #
  # The activity a reader wants is WHEN SOMETHING LAST HAPPENED. That is a
  # question about time, so it must be answered with time.
  test "the latest message wins even when it does not have the highest sequence" do
    {user, _token} = user_with_token()
    s = session_fixture(user, %{title: "s"})

    # A tie, and out of order — both reachable given how sequence is assigned.
    message_at(s, 7, at("2026-09-16 09:00:00"))
    message_at(s, 7, at("2026-09-17 09:22:19"))
    message_at(s, 3, at("2026-09-17 09:30:00"))

    assert [%{last_activity_at: ~N[2026-09-17 09:30:00]}] = Sessions.list_sessions(user.id),
           "last activity must be the newest TIME, not the time of the highest sequence"
  end

  test "last_activity_at is the last message's time" do
    {user, _token} = user_with_token()
    s = session_fixture(user, %{title: "s"})
    message_at(s, 1, at("2026-09-16 09:00:00"))
    message_at(s, 2, at("2026-09-16 09:30:00"))

    assert [%{last_activity_at: ~N[2026-09-16 09:30:00]}] = Sessions.list_sessions(user.id)
  end

  # ⭐ THE COST GUARD. Ordering can be satisfied by a query that scans every
  # message ever mirrored, and the correctness tests above cannot tell the two
  # apart — they pass on the 34-second form. The observable that separates them
  # is the SQL itself: the fast form reaches the last message through the
  # (session_id, sequence) index, and a GROUP BY over `messages` means the scan
  # is back.
  test "the list does not group the whole messages table" do
    {user, _token} = user_with_token()
    s = session_fixture(user, %{title: "s"})
    message_at(s, 1, at("2026-09-16 09:00:00"))

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "list-sql-#{inspect(ref)}",
      [:claudiverse_server, :repo, :query],
      fn _event, _measurements, meta, _ -> send(parent, {ref, meta.query}) end,
      nil
    )

    Sessions.list_sessions(user.id)
    :telemetry.detach("list-sql-#{inspect(ref)}")

    queries = collect(ref, [])

    list_sql =
      Enum.find(queries, fn q ->
        String.contains?(q, "FROM \"sessions\"") and String.contains?(q, "ORDER BY")
      end)

    assert list_sql, "expected to observe the session-list query; saw: #{inspect(queries)}"

    refute String.contains?(list_sql, "GROUP BY"),
           "the list is grouping the messages table again — that is the 34-second query:\n#{list_sql}"

    assert String.contains?(list_sql, "max(m0.inserted_at)"),
           "expected a correlated max() over time, not a proxy for it:\n#{list_sql}"

    refute String.contains?(list_sql, "m0.sequence"),
           "sequence is not a reliable proxy for recency — see the macro's comment:\n#{list_sql}"
  end

  defp collect(ref, acc) do
    receive do
      {^ref, q} -> collect(ref, [q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
