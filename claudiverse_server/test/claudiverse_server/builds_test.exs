defmodule ClaudiverseServer.BuildsTest do
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Builds
  alias ClaudiverseServer.Submissions

  defp build(over \\ %{}) do
    Builds.record(
      Map.merge(
        %{
          sha: "sha#{System.unique_integer([:positive])}",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second),
          verdict: "PASS",
          elf_bytes: 2_591_480,
          differing_bytes: 877_540
        },
        over
      )
    )
  end

  describe "verdict is DERIVED by comparison, not taken from the caller" do
    test "a first build with an ELF is PASS" do
      assert {:ok, b} = build()
      assert b.verdict == "PASS"
    end

    test "differing bytes going UP is a FAIL even though it linked" do
      {:ok, _green} = build(%{differing_bytes: 877_540})

      # ⭐ Byte-exactness is not the bar yet, so the signal is a REGRESSION. An
      # absolute count carries no verdict on its own — 877,540 is fine or
      # alarming depending only on what it was before.
      assert {:ok, b} = build(%{differing_bytes: 900_000})
      assert b.verdict == "FAIL"
    end

    test "differing bytes going DOWN is a PASS — progress is not a regression" do
      {:ok, _} = build(%{differing_bytes: 877_540})
      assert {:ok, b} = build(%{differing_bytes: 100_000})
      assert b.verdict == "PASS"
    end

    test "no ELF is a FAIL regardless of what the caller claims" do
      assert {:ok, b} = build(%{verdict: "PASS", elf_bytes: nil})
      assert b.verdict == "FAIL"
    end

    test "ERROR is preserved — a build that could not RUN is not a failing build" do
      # Collapsing them makes an infrastructure outage look like a code
      # regression, and someone goes hunting for a bug that is not there.
      assert {:ok, b} = build(%{verdict: "ERROR", elf_bytes: nil})
      assert b.verdict == "ERROR"
    end
  end

  describe "the blast radius" do
    defp integrate_one(addr) do
      {:ok, s} =
        Submissions.submit(%{
          address: addr, build: "usa_v200", body_c: "void x(void){}",
          submitted_by: "w1", base_sha: "abc"
        })

      {:ok, _} =
        Submissions.record_gate(s.id, %{
          gate_name: "g", verdict: "PASS", raw_output: "100%",
          positive_control_output: "fired"
        })

      {:ok, _} = Submissions.integrate(s.id, "abc", "integrator")
      s
    end

    test "with no green build ever, the set is UNBOUNDED and says so" do
      integrate_one("0x1000")
      # Returning "everything" while implying it is a short list would be worse
      # than admitting nothing bounds it.
      assert {:unbounded, n} = Builds.suspects()
      assert n >= 1
    end

    test "after a green build, only later integrations are suspect" do
      integrate_one("0x1000")
      {:ok, green} = build()
      Process.sleep(1100)
      later = integrate_one("0x2000")

      assert {:bounded, %{since_sha: sha, integrations: ints}} = Builds.suspects()
      assert sha == green.sha
      assert length(ints) == 1
      assert hd(ints).submission_id == later.id
    end

    test "a REVERTED integration is not a suspect" do
      {:ok, _green} = build()
      Process.sleep(1100)
      s = integrate_one("0x3000")
      {:ok, _} = Submissions.revert(s.id, "already undone")

      assert {:bounded, %{integrations: ints}} = Builds.suspects()
      assert ints == []
    end
  end

  describe "due?" do
    test "due when never built" do
      assert {true, why} = Builds.due?()
      assert why =~ "has ever been recorded"
    end

    test "due on the integration threshold" do
      {:ok, _} = build()
      Process.sleep(1100)
      for i <- 1..3, do: integrate_one("0x#{4000 + i}")

      assert {false, _} = Builds.due?(every: 10)
      assert {true, why} = Builds.due?(every: 3)
      assert why =~ "3 integrations"
    end

    test "the TIME floor fires even with zero integrations" do
      # ⚠️ Without it a slow week goes unchecked indefinitely, and the blast
      # radius this component exists to bound grows without anyone noticing.
      old = DateTime.utc_now() |> DateTime.add(-30 * 3600, :second) |> DateTime.truncate(:second)
      {:ok, _} = build(%{started_at: old})

      # Default floor is 24h because a full build costs ~60 MINUTES on the
      # single-owner VM; a shorter floor would starve the workers that need it.
      assert {false, _} = Builds.due?(every: 10, hours: 48)
      assert {true, why} = Builds.due?(every: 10, hours: 24)
      assert why =~ "since the last build"
    end
  end
end
