defmodule ClaudiverseServer.Builds do
  @moduledoc """
  Component D — the periodic full build, and the blast radius it bounds.

  The value is not the build result. It is that a RED build plus the previous
  GREEN one define a closed set of integrations, exactly one of which is at
  fault. Without it, "master is broken" has no bound and someone bisects by
  hand — which is how the link stayed broken on master for days.
  """
  import Ecto.Query

  alias ClaudiverseServer.Knowledge.{Build, Integration}
  alias ClaudiverseServer.Repo

  @doc """
  Record a build, deriving PASS/FAIL by COMPARING against the last green rather
  than trusting the caller.

  Byte-exactness is not the bar yet, so the signal is a REGRESSION: differing
  bytes going up against the last green is a FAIL even though the build linked.
  An absolute count carries no verdict on its own — 877,540 is either fine or
  alarming depending only on what it was before.
  """
  def record(attrs) do
    attrs = stringify(attrs)
    region = attrs["region"] || "usa"
    prev = last_green(attrs["fleet"] || "lorem-fleet", region)

    verdict =
      cond do
        attrs["verdict"] == "ERROR" -> "ERROR"
        is_nil(attrs["elf_bytes"]) -> "FAIL"
        regressed?(prev, attrs["differing_bytes"]) -> "FAIL"
        true -> "PASS"
      end

    attrs
    |> Map.put("verdict", verdict)
    |> Map.put_new("integrations_since", count_integrations_since(prev))
    |> then(&Build.changeset(%Build{}, &1))
    |> Repo.insert()
  end

  # ⚠️ The verdict keys on DIFFERING BYTES, never on ELF SIZE. Measured
  # 2026-09-10: two worktrees at effectively the same source produced ELFs of
  # 2,590,436 and 2,591,480 — 1,044 bytes apart — while differing_bytes was
  # IDENTICAL at 877,540 both times. Cause unconfirmed, most likely absolute
  # paths embedded by the build. elf_bytes is therefore evidence that an ELF was
  # produced, and NOT a comparator across builds.
  defp regressed?(nil, _), do: false
  defp regressed?(_prev, nil), do: false
  defp regressed?(%Build{differing_bytes: nil}, _), do: false
  defp regressed?(%Build{differing_bytes: was}, now) when is_integer(now), do: now > was
  defp regressed?(_, _), do: false

  def last_green(fleet \\ "lorem-fleet", region \\ "usa") do
    from(b in Build,
      where: b.fleet == ^fleet and b.region == ^region and b.verdict == "PASS",
      order_by: [desc: b.started_at, desc: b.id],
      limit: 1
    )
    |> Repo.one()
  end

  def last_build(fleet \\ "lorem-fleet", region \\ "usa") do
    from(b in Build,
      where: b.fleet == ^fleet and b.region == ^region,
      order_by: [desc: b.started_at, desc: b.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp count_integrations_since(nil), do: Repo.aggregate(Integration, :count)

  defp count_integrations_since(%Build{started_at: at}),
    do: from(i in Integration, where: i.integrated_at > ^at) |> Repo.aggregate(:count)

  @doc """
  ⭐ THE BLAST RADIUS. Integrations that landed after the last green build —
  when the current build is red, the culprit is in exactly this set.

  Returns them newest-first, because the most recent is the most likely and is
  also the cheapest to revert.
  """
  def suspects(fleet \\ "lorem-fleet", region \\ "usa") do
    case last_green(fleet, region) do
      nil ->
        # No green build has ever been recorded, so nothing bounds the set. Say
        # so rather than returning everything and implying it is a short list.
        {:unbounded, Repo.aggregate(Integration, :count)}

      %Build{started_at: at, sha: sha} ->
        rows =
          from(i in Integration,
            where: i.integrated_at > ^at and is_nil(i.reverted_at),
            order_by: [desc: i.integrated_at]
          )
          |> Repo.all()

        {:bounded, %{since_sha: sha, since: at, integrations: rows}}
    end
  end

  @doc """
  Is a full build due? True when `every` integrations have landed since the last
  build, OR `hours` have elapsed — whichever comes first.

  ⚠️ The TIME floor is not decoration. Without it a slow week goes unchecked
  indefinitely, and the blast radius that this component exists to bound grows
  without anyone noticing it growing.
  """
  def due?(opts \\ []) do
    every = Keyword.get(opts, :every, 10)
    # ⚠️ 24h, not 4h. MEASURED 2026-09-10: a full build takes 59.8 MINUTES, not
    # the ~15 assumed when this default was chosen. At a 4h floor that is a 25%
    # duty cycle on the SINGLE-OWNER colima VM — which would starve the very
    # workers whose own gates need it. The integration threshold is the primary
    # trigger; the time floor exists only so a quiet week cannot go unchecked
    # forever.
    hours = Keyword.get(opts, :hours, 24)
    fleet = Keyword.get(opts, :fleet, "lorem-fleet")
    region = Keyword.get(opts, :region, "usa")

    case last_build(fleet, region) do
      nil ->
        {true, "no build has ever been recorded"}

      %Build{started_at: at} = b ->
        since = count_integrations_since(b)
        age_h = DateTime.diff(DateTime.utc_now(), at, :second) / 3600

        cond do
          since >= every -> {true, "#{since} integrations since the last build (threshold #{every})"}
          age_h >= hours -> {true, "#{Float.round(age_h, 1)}h since the last build (threshold #{hours}h)"}
          true -> {false, "#{since}/#{every} integrations, #{Float.round(age_h, 1)}/#{hours}h"}
        end
    end
  end

  def list(opts \\ []) do
    from(b in Build, order_by: [desc: b.started_at, desc: b.id], limit: ^(opts[:limit] || 20))
    |> Repo.all()
  end

  defp stringify(attrs) when is_map(attrs),
    do: for({k, v} <- attrs, into: %{}, do: {to_string(k), v})
end
