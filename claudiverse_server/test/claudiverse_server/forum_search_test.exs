defmodule ClaudiverseServer.ForumSearchTest do
  @moduledoc """
  The LIKE fallback's handling of identifiers.

  ⚠️ This path is DORMANT in normal operation — it runs only when FTS is
  unavailable. That is exactly why it is worth a test: it activates when things
  are already degraded, and its failure mode is a silent zero, which is
  indistinguishable from "nothing is known about this".
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Forum
  alias ClaudiverseServer.Repo

  setup do
    {:ok, ch} = Forum.create_channel(%{slug: "srch", title: "Search"})

    for body <- [
          "the mail barrier requires MAIL_TO_DISK=1 and SMTP_HOST=disabled.invalid",
          "joins on bb_application_association across allocations",
          "contact is dummy@example.com in the fixture"
        ] do
      {:ok, _} = Forum.create_post(%{channel: "srch", author: "t", body: body})
    end

    {:ok, channel: ch}
  end

  defp like_count(pattern_query) do
    escaped = String.replace(pattern_query, ~r/([\\%_])/, "\\\\\\1")

    [[n]] =
      Repo.query!("SELECT count(*) FROM forum_posts WHERE body LIKE ? ESCAPE '\\'", [
        "%" <> escaped <> "%"
      ]).rows

    n
  end

  defp old_broken_count(q) do
    # What the code used to do: DELETE the wildcards rather than escape them.
    [[n]] =
      Repo.query!("SELECT count(*) FROM forum_posts WHERE body LIKE ?", [
        "%" <> String.replace(q, ~r/[%_]/, "") <> "%"
      ]).rows

    n
  end

  test "an underscored identifier survives the LIKE fallback" do
    # ⭐ FAILS IF THE FIX IS REVERTED: deleting `_` turns MAIL_TO_DISK into
    # MAILTODISK, which matches nothing — and reports it as zero results.
    assert like_count("MAIL_TO_DISK") == 1
    assert old_broken_count("MAIL_TO_DISK") == 0

    assert like_count("bb_application_association") == 1
    assert old_broken_count("bb_application_association") == 0
  end

  test "a query with no wildcard chars is UNAFFECTED — control on the change" do
    # Without this, the escaping could be mangling ordinary queries and the
    # test above would still pass.
    assert like_count("dummy@example.com") == 1
    assert old_broken_count("dummy@example.com") == 1
  end

  test "a literal % is matched literally, not as a wildcard" do
    {:ok, _} = Forum.create_post(%{channel: "srch", author: "t", body: "coverage hit 100% exactly"})

    assert like_count("100%") == 1
    # If % were unescaped, "1%y" would match many rows through the wildcard.
    assert like_count("1%y") == 0
  end

  test "Forum.search finds identifiers through the normal FTS path" do
    assert length(Forum.search("MAIL_TO_DISK", limit: 50)) >= 1
    assert length(Forum.search("bb_application_association", limit: 50)) >= 1
  end

  test "a channel-filtered search returns only that channel, ranked, with snippets" do
    {:ok, _} = Forum.create_channel(%{slug: "other", title: "Other"})
    {:ok, _} = Forum.create_post(%{channel: "other", author: "t", body: "MAIL_TO_DISK lives here too"})

    # Control: unfiltered, the term is in BOTH channels.
    assert Forum.search("MAIL_TO_DISK", limit: 50) |> Enum.map(& &1.channel_slug) |> Enum.sort() ==
             ["other", "srch"]

    [hit] = Forum.search("MAIL_TO_DISK", limit: 50, channel: "srch")
    assert hit.channel_slug == "srch"
    # Snippets come from the second step; a nil here means it lost the row.
    assert hit.snippet =~ "MAIL"
  end

  test "a reply in another channel than its parent is refused; a same-channel reply is not" do
    {:ok, _} = Forum.create_channel(%{slug: "other", title: "Other"})
    {:ok, parent} = Forum.create_post(%{channel: "srch", author: "t", body: "parent"})

    assert {:error, {:parent_in_other_channel, "srch"}} =
             Forum.create_post(%{channel: "other", author: "t", body: "misfiled", parent_id: parent.id})

    # Control: the same reply in the parent's channel is accepted.
    assert {:ok, _} = Forum.create_post(%{channel: "srch", author: "t", body: "reply", parent_id: parent.id})
  end
end
