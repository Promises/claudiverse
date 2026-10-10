defmodule ClaudiverseServer.CustodianTest do
  @moduledoc """
  The custodian's FAILURE path.

  A scheduled backup that fails only into a log file is a backup nobody knows
  is broken — its silence is indistinguishable from success. These tests hold
  the alarm to that standard: it must actually reach the forum.
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Forum
  alias ClaudiverseServer.Knowledge.Custodian

  setup do
    dir = Path.join(System.tmp_dir!(), "custodian-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, ch} =
      Forum.create_channel(%{slug: "fleet-control", title: "Fleet control"})

    {:ok, dir: dir, channel: ch}
  end

  test "a FAILED snapshot posts a loud alarm to #fleet-control", %{dir: dir, channel: channel} do
    # keep: 0 is refused before any VACUUM runs — an induced failure that needs
    # no corruption and no multi-GB database.
    result = Custodian.run_once(dir: dir, keep: 0)

    assert %{ok: false, error: err} = result
    assert err =~ "keep must be at least 1"

    posts = Forum.list_posts(channel)
    assert [post] = posts

    assert post.author == "custodian"
    assert post.title =~ "SNAPSHOT FAILED"

    # The body must carry what an operator needs to act, not just that it broke.
    assert post.body =~ "keep must be at least 1"
    assert post.body =~ dir
    assert post.body =~ "mix claudiverse.kb.snapshot"

    # ⭐ And it must say what the failure MEANS. "Snapshot failed" reads as a
    # chore; "there is one copy of the database" reads as urgent.
    assert post.body =~ "one copy"
  end

  test "the alarm survives a post it cannot make", %{dir: dir, channel: ch} do
    # Delete the channel so create_post is rejected. The run must still report
    # its failure rather than crashing — losing the snapshot AND the process
    # would turn one problem into two.
    Repo.delete!(ch)

    assert %{ok: false, error: err} = Custodian.run_once(dir: dir, keep: 0)
    assert err =~ "keep must be at least 1"
  end

  test "status is :never before any run, and reports enabled/dir" do
    # The app starts the custodian disabled in test.
    s = Custodian.status()
    assert s.last == :never
    refute s.enabled
  end

  test "disabled is the default, so dev and test never write snapshots", %{dir: dir} do
    # Nothing was configured for this app env, so a started custodian is idle.
    assert File.ls!(dir) == []
    refute Custodian.status().enabled
  end

  test "a nil dir from an unset SNAPSHOT_DIR falls back, it does not reach mkdir_p!(nil)" do
    # runtime.exs sets `dir: System.get_env("SNAPSHOT_DIR")`, which is nil when
    # unset. Keyword.get returns a present key's nil rather than the default, so
    # this would have crashed on the first scheduled run — on the box, at 10
    # minutes past boot, not here.
    assert %{ok: false, error: err} = Custodian.run_once(dir: nil, keep: 0)
    assert err =~ "keep must be at least 1"
  end
end
