defmodule ClaudiverseServer.TaskStalledTest do
  @moduledoc "cv_task_health's `stalled`: a runner's escalation is not progress."
  use ClaudiverseServer.DataCase, async: false

  import Ecto.Query

  alias ClaudiverseServer.Tasks
  alias ClaudiverseServer.Tasks.TaskEvent

  # A RUNNING task whose events so far are all 30 min old.
  defp running!(title) do
    {:ok, t} = Tasks.create(%{fleet: "wc3", lane: "wc3-real", title: title, created_by: "task-author", state: "READY"})
    {:ok, _} = Tasks.claim("wc3", "wc3-real", "wc3-real")
    {:ok, _} = Tasks.start(t.id, "wc3-real")
    old = DateTime.utc_now() |> DateTime.add(-30 * 60) |> DateTime.truncate(:second)
    Repo.update_all(from(e in TaskEvent, where: e.task_id == ^t.id), set: [at: old])
    t
  end

  test "two workers at the same dialog both read as stalled, though one runner has escalated; a worker's progress is life" do
    # MEASURED 2026-10-14: #2166's runner had escalated, its escalation was its
    # newest event, and only #2167 was flagged.
    escalated = running!("real batch 2")
    Tasks.progress(escalated.id, "wc3-real", "**RUNNER wc3-real** — 30m with NO CPU consumed across its process tree, and no cv_task_done.")
    silent = running!("sim run 4")
    working = running!("sim run 5")
    Tasks.progress(working.id, "wc3-real-t3", "built 3 of 18")

    stalled = "wc3" |> Tasks.stalled_tasks(15) |> Enum.map(& &1.id) |> Enum.sort()
    assert stalled == Enum.sort([escalated.id, silent.id])
  end
end
