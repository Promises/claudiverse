defmodule ClaudiverseServer.AnthropicAuthAssignmentTest do
  @moduledoc """
  The seat -> account mapping, and the header it comes from.

  These cover the two ways this feature can fail QUIETLY: a lease that records
  nothing (leaving the question unanswerable, which is the status quo it exists
  to fix) and a lease that FAILS because recording failed (which would be worse
  than the problem — a stalled seat instead of a missing diagnostic).
  """
  # Not async: SQLite has one writer, and parallel sandbox transactions on
  # anthropic_auths timed out with "Database busy" (measured 2026-10-04).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth
  alias ClaudiverseServerWeb.Plugs.Auth

  defp auth!(label) do
    Repo.insert!(%AnthropicAuth{label: label, priority: 100, status: "available"})
  end

  defp conn_with(header) do
    c = %Plug.Conn{req_headers: []}
    if header, do: %{c | req_headers: [{"x-claudiverse-client", header}]}, else: c
  end

  describe "header parsing" do
    test "both fields" do
      assert %{title: "ipsum-admin", claude_session_id: "425a0547"} =
               Auth.client_identity(conn_with("title=ipsum-admin; id=425a0547"))
    end

    test "startup lease: title only, id empty — the expected first request" do
      assert %{title: "ipsum-admin", claude_session_id: nil} =
               Auth.client_identity(conn_with("title=ipsum-admin; id="))
    end

    test "percent-encoded title round-trips" do
      assert %{title: "Claude 10:23:45 AM"} =
               Auth.client_identity(conn_with("title=Claude%2010%3A23%3A45%20AM; id=x"))
    end

    test "an encoded separator cannot forge a second field" do
      # The client encodes "; " so a hostile title stays one value.
      assert %{title: "evil; id=999", claude_session_id: "real"} =
               Auth.client_identity(conn_with("title=evil%3B%20id%3D999; id=real"))
    end

    test "absent or malformed header degrades to unidentified, never raises" do
      assert %{title: nil, claude_session_id: nil} = Auth.client_identity(conn_with(nil))
      assert %{title: nil, claude_session_id: nil} = Auth.client_identity(conn_with("garbage"))
      assert %{title: nil} = Auth.client_identity(conn_with("=;=;="))
    end
  end

  describe "record_assignment/3" do
    test "records the seat and reads back with its label" do
      a = auth!("Personal")
      assert :ok = AnthropicAuths.record_assignment(%{title: "ipsum-admin", claude_session_id: "s1"}, a.id, "lease")

      assert [row] = AnthropicAuths.list_assignments()
      assert row.title == "ipsum-admin"
      assert row.anthropic_auth_id == a.id
      assert row.anthropic_auth.label == "Personal"
      assert row.via == "lease"
    end

    test "a re-lease UPDATES the seat's row instead of appending" do
      p = auth!("Personal")
      w = auth!("Work")
      i = %{title: "ipsum-admin", claude_session_id: "s1"}

      :ok = AnthropicAuths.record_assignment(i, p.id, "lease")
      :ok = AnthropicAuths.record_assignment(i, w.id, "failover")

      assert [row] = AnthropicAuths.list_assignments()
      assert row.anthropic_auth_id == w.id
      assert row.via == "failover"
    end

    test "the startup lease's missing session id fills in on the next call" do
      a = auth!("Personal")
      :ok = AnthropicAuths.record_assignment(%{title: "ipsum-orchestrator", claude_session_id: nil}, a.id, "lease")
      assert [%{claude_session_id: nil}] = AnthropicAuths.list_assignments()

      :ok = AnthropicAuths.record_assignment(%{title: "ipsum-orchestrator", claude_session_id: "uuid"}, a.id, "upgrade")
      assert [%{claude_session_id: "uuid"}] = AnthropicAuths.list_assignments()
    end

    test "an unidentified seat is skipped, not an error" do
      a = auth!("Personal")
      assert :ok = AnthropicAuths.record_assignment(%{title: nil, claude_session_id: nil}, a.id, "lease")
      assert [] = AnthropicAuths.list_assignments()
    end

    test "🔴 a bad auth_id must NOT raise — a lease may never fail on bookkeeping" do
      assert :ok = AnthropicAuths.record_assignment(%{title: "ipsum-admin"}, 999_999, "lease")
      assert [] = AnthropicAuths.list_assignments()
    end


    test "🔴 a restart must REPLACE the seat's row, not add a second one" do
      # Keying on instance_id let two rows share a title whenever the instances
      # differed — and a restart always mints a new instance. Measured in
      # production: 19 rows for ~10 seats, three of them under one title.
      a = auth!("Personal")
      i = %{title: "ipsum-admin", claude_session_id: nil}

      :ok = AnthropicAuths.record_assignment(Map.put(i, :instance_id, "inst-1"), a.id, "lease")
      :ok = AnthropicAuths.record_assignment(Map.put(i, :instance_id, "inst-2"), a.id, "lease")
      :ok = AnthropicAuths.record_assignment(Map.put(i, :instance_id, "inst-3"), a.id, "lease")

      assert [row] = AnthropicAuths.list_assignments(),
             "one seat name must map to exactly one row"

      assert row.instance_id == "inst-3", "the LIVE instance owns the name"
    end


    test "🔴 a LEGACY row (instance_id NULL) is displaced, not left behind" do
      # NULL != 'abc' is NULL in SQL, not TRUE, so a bare inequality skips every
      # legacy row — exactly the ones needing replacement. Measured in
      # production: a restarted seat's pre-instance_id row survived beside the
      # new one. The other tests all used rows that HAD an instance_id.
      a = auth!("Personal")

      :ok = AnthropicAuths.record_assignment(%{title: "seat-x", claude_session_id: nil}, a.id, "lease")
      assert [%{instance_id: nil}] = AnthropicAuths.list_assignments()

      :ok = AnthropicAuths.record_assignment(%{title: "seat-x", instance_id: "inst-new"}, a.id, "lease")

      assert [row] = AnthropicAuths.list_assignments(),
             "the legacy row must be displaced, not kept alongside"

      assert row.instance_id == "inst-new"
    end

    test "two different seats keep their own rows" do
      a = auth!("Personal")
      :ok = AnthropicAuths.record_assignment(%{title: "ipsum-admin", instance_id: "i1"}, a.id, "lease")
      :ok = AnthropicAuths.record_assignment(%{title: "ipsum-orchestrator", instance_id: "i2"}, a.id, "lease")
      assert length(AnthropicAuths.list_assignments()) == 2
    end

    test "an unknown via is recorded, not rejected" do
      a = auth!("Personal")
      :ok = AnthropicAuths.record_assignment(%{title: "x"}, a.id, "something-new")
      assert [%{via: "other:something-new"}] = AnthropicAuths.list_assignments()
    end
  end

  describe "note_seat_title/2 — the seat map follows a rename" do
    test "🔴 THE PRODUCTION SHAPE: assignment and session never shared a value" do
      # Measured: the seat leased under a timestamp (pre-hook, no session id) and
      # created its session under its UUID moments later. Only instance_id spans
      # both, which is the whole reason it exists.
      a = auth!("Personal")
      inst = "inst-abc"

      :ok = AnthropicAuths.record_assignment(
        %{title: "Claude 11:41:02 AM", claude_session_id: nil, instance_id: inst}, a.id, "lease")

      # session was created under the UUID, then renamed twice
      :ok = AnthropicAuths.note_seat_title(%{instance_id: inst, claude_session_id: "uuid-1"}, "uuid-1")
      :ok = AnthropicAuths.note_seat_title(%{instance_id: inst, claude_session_id: "uuid-1"}, "runejs-f3")
      :ok = AnthropicAuths.note_seat_title(%{instance_id: inst, claude_session_id: "uuid-1"}, "hello-0world")

      assert [row] = AnthropicAuths.list_assignments()
      assert row.title == "hello-0world"
      assert row.claude_session_id == "uuid-1"
      assert row.instance_id == inst
    end

    test "a re-lease after a rename updates the SAME row, not a second one" do
      p = auth!("Personal")
      w = auth!("Work")
      i = %{title: "Claude 11:41:02 AM", claude_session_id: nil, instance_id: "inst-1"}

      :ok = AnthropicAuths.record_assignment(i, p.id, "lease")
      :ok = AnthropicAuths.note_seat_title(%{instance_id: "inst-1"}, "hello-0world")
      # a 429 failover later: same seat, new account, title already changed
      :ok = AnthropicAuths.record_assignment(%{i | title: "hello-0world"}, w.id, "failover")

      assert [row] = AnthropicAuths.list_assignments()
      assert row.title == "hello-0world"
      assert row.anthropic_auth_id == w.id
      assert row.via == "failover"
    end

    test "a stale namesake is displaced rather than blocking the rename" do
      a = auth!("Personal")
      :ok = AnthropicAuths.record_assignment(%{title: "hello-0world", instance_id: "dead"}, a.id, "lease")
      :ok = AnthropicAuths.record_assignment(%{title: "Claude 11:41:02 AM", instance_id: "live"}, a.id, "lease")

      :ok = AnthropicAuths.note_seat_title(%{instance_id: "live"}, "hello-0world")

      assert [row] = AnthropicAuths.list_assignments()
      assert row.instance_id == "live"
    end

    test "a client without an instance_id is ignored, not an error" do
      a = auth!("Personal")
      :ok = AnthropicAuths.record_assignment(%{title: "legacy", claude_session_id: nil}, a.id, "lease")
      assert :ok = AnthropicAuths.note_seat_title(%{title: "legacy"}, "renamed")
      # unchanged: without an instance there is nothing safe to match on
      assert [%{title: "legacy"}] = AnthropicAuths.list_assignments()
    end
  end
end
