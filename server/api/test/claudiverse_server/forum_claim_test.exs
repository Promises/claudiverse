defmodule ClaudiverseServer.ForumClaimTest do
  @moduledoc """
  Claiming a forum task post (`Forum.claim_post/3`): one statement decides it.
  A runner lists `incoming` posts and then claims one; whatever happened to the
  post in between must decide the claim, not the list it was read from.
  MEASURED 2026-10-12: ipsum-orchestrator set validator #31192 done as a held duplicate,
  and runner ipsum-w7 still ran a seat on it.
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Forum

  setup do
    {:ok, _} = Forum.create_channel(%{slug: "claims", title: "Claims"})
    :ok
  end

  defp task!(attrs \\ %{}) do
    {:ok, post} = Forum.create_post(Map.merge(%{channel: "claims", author: "t", title: "a task", body: "do it", status: "incoming"}, attrs))
    post
  end

  test "an unowned incoming post is claimed once; the second claimant is told who holds it" do
    p = task!()
    assert {:ok, %{owner: "w1-t1"}} = Forum.claim_post(p.id, "w1-t1")
    assert {:error, {:already_claimed, "w1-t1"}} = Forum.claim_post(p.id, "w2-t1")
  end

  test "a post set done or archived before the claim is not claimed" do
    done = task!()
    {:ok, _} = Forum.set_status(done.id, "done")
    assert {:error, {:not_claimable, "done"}} = Forum.claim_post(done.id, "w1-t1")
    assert %{owner: nil} = Forum.get_post(done.id)

    archived = task!()
    {:ok, _} = Forum.archive_post(archived.id)
    assert {:error, {:not_claimable, "archived"}} = Forum.claim_post(archived.id, "w1-t1")
    assert %{owner: nil} = Forum.get_post(archived.id)
  end

  test "a missing post is not found" do
    assert {:error, :not_found} = Forum.claim_post(999_999_999, "w1-t1")
  end
end
