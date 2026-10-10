defmodule ClaudiverseServerWeb.KnowledgeControllerTest do
  use ClaudiverseServerWeb.ConnCase

  import ClaudiverseServer.Fixtures

  setup do
    {user, token} = user_with_token()
    %{user: user, token: token}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "a RULING can record the observable that retires it" do
    test "ruling_revoked_by survives the known-params filter", %{conn: conn, token: token} do
      # ⛔ REGRESSION. There was no field for a revoked-by, so callers passed
      # `ruling_revoked_by` and the controller's `Map.take(@known)` DROPPED IT
      # SILENTLY — the write succeeded, returned ok, and the clause was gone.
      # Measured 2026-09-11: four rulings reached the store carrying no expiry
      # clause at all, which is the exact failure the rule exists to prevent.
      clause = "someone measures X at Y and sees Z"

      created =
        conn
        |> auth(token)
        |> post("/api/kb/documents", %{
          kind: "RULING",
          scope: "fleet",
          title: "a ruling with an expiry",
          slug: "revokable-ruling",
          body_md: "the decision",
          author: "t",
          ruling_revoked_by: clause
        })
        |> json_response(200)

      id = created["document"]["id"]

      shown =
        build_conn() |> auth(token) |> get("/api/kb/documents/#{id}") |> json_response(200)

      assert shown["revision"]["front_matter"]["revoked_by"] == clause,
             "the revoked-by was dropped again — is promote_front_matter/1 still wired into create/2?"
    end

    test "fact_bound, fact_derived_under and demonstrated_by survive too", %{
      conn: conn,
      token: token
    } do
      # ⛔ REGRESSION, and this is the expensive one. MEASURED 2026-09-11: ~20
      # FACTs were filed carrying an explicit fact_bound — what each did NOT
      # establish — and every one was discarded. front_matter came back {} on
      # all of them. The bound is the part that stops a claim being read wider
      # than it was measured, so losing it silently is worse than losing the
      # body.
      created =
        conn
        |> auth(token)
        |> post("/api/kb/documents", %{
          kind: "FACT",
          scope: "fleet",
          title: "a bounded fact",
          slug: "bounded-fact",
          body_md: "the claim",
          author: "t",
          fact_command: "run the thing",
          fact_fails_when: "it prints NOPE",
          fact_fails_when_status: "DEMONSTRATED",
          fact_bound: "n=3, one region, one build",
          fact_derived_under: "master abc1234",
          demonstrated_by: "injected a mutant and saw NOPE"
        })
        |> json_response(200)

      fm =
        build_conn()
        |> auth(token)
        |> get("/api/kb/documents/#{created["document"]["id"]}")
        |> json_response(200)
        |> get_in(["revision", "front_matter"])

      assert fm["bound"] == "n=3, one region, one build"
      assert fm["derived_under"] == "master abc1234"
      assert fm["demonstrated_by"] == "injected a mutant and saw NOPE"
    end
  end

  defp fact(conn, token, slug, extra \\ %{}) do
    body =
      Map.merge(
        %{
          kind: "FACT",
          scope: "fleet",
          title: "t-#{slug}",
          slug: slug,
          created_by: "test",
          body_md: "claim body for #{slug}",
          author: "test",
          fact_command: "/usr/bin/grep -c foo bar",
          fact_fails_when: "prints 0",
          fact_fails_when_status: "DEMONSTRATED"
        },
        extra
      )

    conn |> auth(token) |> post("/api/kb/documents", body)
  end

  test "a document round-trips WHOLE — no feed truncation", %{conn: conn, token: token} do
    # 4 KB body: well past the forum's ~1,499-char read cap. The whole point of
    # a separate store is that a document is not truncated, and truncation is
    # tail-biased so it removes exactly the qualifying fields.
    big = String.duplicate("x", 4000) <> " TAIL-MARKER-END"
    assert %{"ok" => true} = fact(conn, token, "big", %{body_md: big}) |> json_response(200)

    body =
      build_conn() |> auth(token) |> get("/api/kb/documents/big") |> json_response(200)

    assert body["revision"]["body_md"] == big
    assert String.contains?(body["revision"]["body_md"], "TAIL-MARKER-END")
  end

  test "corrections are ALWAYS returned, empty before and populated after",
       %{conn: conn, token: token} do
    assert %{"document" => %{"id" => claim_id}} =
             fact(conn, token, "c-claim") |> json_response(200)

    # positive control: the key exists and is empty
    assert build_conn() |> auth(token) |> get("/api/kb/documents/c-claim") |> json_response(200) |>
             Map.fetch!("corrections") == []

    assert %{"document" => %{"id" => retr_id}} =
             fact(build_conn(), token, "c-retr") |> json_response(200)

    assert %{"ok" => true} =
             build_conn()
             |> auth(token)
             |> post("/api/kb/relations", %{
               from_document_id: retr_id,
               to_document_id: claim_id,
               kind: "RETRACTS",
               author: "test"
             })
             |> json_response(200)

    body = build_conn() |> auth(token) |> get("/api/kb/documents/c-claim") |> json_response(200)
    assert [%{"kind" => "RETRACTS"}] = body["corrections"]
  end

  test "a revised FACT announces itself on the DEFAULT read path", %{conn: conn, token: token} do
    # ⛔ Behaviour CHANGED 2026-09-11. FACT revisions were refused with a 409.
    # The rule's purpose was that an edited claim and the cited claim must not
    # become SILENTLY different — so revisions are now allowed and the read path
    # carries the signal instead. A queryable history nobody queries is the same
    # as no history, which is why this asserts the DEFAULT GET, not /history.
    assert %{"ok" => true} = fact(conn, token, "imm") |> json_response(200)

    before = build_conn() |> auth(token) |> get("/api/kb/documents/imm") |> json_response(200)
    assert before["revisions"]["count"] == 1

    assert %{"ok" => true} =
             build_conn()
             |> auth(token)
             |> post("/api/kb/documents/imm/revisions", %{
               body_md: "edited",
               author: "someone-else",
               fact_command: "run it",
               fact_fails_when: "NOPE",
               fact_fails_when_status: "ASSERTED"
             })
             |> json_response(200)

    after_ = build_conn() |> auth(token) |> get("/api/kb/documents/imm") |> json_response(200)

    assert after_["revisions"]["count"] == 2,
           "a reader citing this fact must be told the claim has been revised"
  end

  test "an ASSERTED fact reports sweep_status untested", %{conn: conn, token: token} do
    assert %{"ok" => true} =
             fact(conn, token, "asrt", %{fact_fails_when_status: "ASSERTED"}) |> json_response(200)

    body = build_conn() |> auth(token) |> get("/api/kb/documents/asrt") |> json_response(200)
    assert body["sweep_status"] == "untested"
  end

  test "a search SYNTAX ERROR is 400, never an empty result set",
       %{conn: conn, token: token} do
    assert %{"ok" => true} = fact(conn, token, "srch") |> json_response(200)

    # positive control: a well-formed query finds it, so the 400 below is about
    # syntax and not about an empty store.
    ok = build_conn() |> auth(token) |> get("/api/kb/search", q: "claim") |> json_response(200)
    assert length(ok["results"]) >= 1

    # ⭐ A hyphen used to RAISE, and this test used to assert the resulting 400
    # — encoding the bug as the contract. Queries are now quoted as phrases, so
    # a flag or a path is an ordinary literal search.
    hyphen = build_conn() |> auth(token) |> get("/api/kb/search", q: "-O2 -G0") |> json_response(200)
    assert is_list(hyphen["results"])

    slash = build_conn() |> auth(token) |> get("/api/kb/search", q: "tools/ee/vm.sh") |> json_response(200)
    assert is_list(slash["results"])

    # The PRINCIPLE the old test was defending still holds and is still tested:
    # a malformed query is a 400, never a silent []. It is only reachable
    # through raw=1 now, because that is the mode where the caller owns the
    # syntax.
    err =
      build_conn()
      |> auth(token)
      |> get("/api/kb/search", q: ~s("unterminated), raw: "1")
      |> json_response(400)

    assert err["error"] =~ "syntax"
  end

  test "anchors resolve across address spellings", %{conn: conn, token: token} do
    assert %{"ok" => true} =
             conn
             |> auth(token)
             |> post("/api/kb/documents", %{
               kind: "NOTE",
               scope: "project:lorem-fleet",
               title: "anchored",
               slug: "anch",
               created_by: "test",
               body_md: "b",
               author: "test",
               anchors: [%{"type" => "address", "value" => "0x00336B88"}]
             })
             |> json_response(200)

    for spelling <- ["0x00336B88", "0x336b88", "336B88"] do
      body =
        build_conn()
        |> auth(token)
        |> get("/api/kb/anchors/address/#{spelling}")
        |> json_response(200)

      assert Enum.map(body["documents"], & &1["slug"]) == ["anch"], "failed for #{spelling}"
    end
  end

  describe "relate accepts slugs" do
    test "a correction can be wired by SLUG, not just internal id", %{conn: conn, token: token} do
      assert %{"ok" => true} = fact(conn, token, "rel-target") |> json_response(200)
      assert %{"ok" => true} = fact(conn, token, "rel-source") |> json_response(200)

      # ⭐ Slugs are the stable public handle; row ids are not. Making every
      # client resolve ids first means every client re-implements the lookup —
      # and one that resolves the WRONG id writes a correction pointing at the
      # wrong claim, which reads exactly like a correct one.
      body =
        build_conn()
        |> auth(token)
        |> post("/api/kb/relations", %{
          from: "rel-source",
          to: "rel-target",
          kind: "NARROWS",
          author: "t"
        })
        |> json_response(200)

      assert body["ok"]

      # and it must SURFACE on a plain read of the corrected claim
      read = build_conn() |> auth(token) |> get("/api/kb/documents/rel-target") |> json_response(200)
      assert [%{"kind" => "NARROWS"}] = read["corrections"]
    end

    test "an unknown slug is a 422 naming it, not a silent no-op", %{conn: conn, token: token} do
      assert %{"ok" => true} = fact(conn, token, "rel-only") |> json_response(200)

      # A relation that quietly fails to exist is the worst outcome here: the
      # caller believes the claim is corrected and readers still get it clean.
      body =
        build_conn()
        |> auth(token)
        |> post("/api/kb/relations", %{
          from: "rel-only",
          to: "does-not-exist",
          kind: "NARROWS",
          author: "t"
        })
        |> json_response(422)

      assert body["error"] =~ "does-not-exist"
    end
  end
end
