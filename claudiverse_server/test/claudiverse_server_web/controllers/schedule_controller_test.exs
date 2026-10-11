defmodule ClaudiverseServerWeb.ScheduleControllerTest do
  @moduledoc """
  /api/schedules: who may schedule for whom, the 422s that name the field,
  and the prompt kept exactly (20,000 characters round-trip, 20,001 refused
  with nothing stored, multi-byte text counted in characters).
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, Schedules}

  setup do
    {user, api} = user_with_token()
    %{user: user, api: api, app: Accounts.create_user_api_token(user, "app")}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp add(token, body) do
    as(token) |> post("/api/schedules", Map.merge(%{name: "weekly", cron: "0 12 * * 0", tz: "Europe/Oslo", prompt: "Review the week."}, body))
  end

  defp count(user), do: length(Schedules.list(user.id))

  # --- 6. permissions ----------------------------------------------------------

  test "a seat schedules for itself; the target defaults to it", ctx do
    r = add(ctx.api, %{self: "ipsum-admin"}) |> json_response(201)
    assert %{"target" => "ipsum-admin", "created_by" => "ipsum-admin", "next_fire_local" => "Sun " <> _} = r["schedule"]
  end

  test "a seat cannot schedule for another seat", ctx do
    r = add(ctx.api, %{self: "ipsum-admin", target: "ipsum-orchestrator"})
    assert json_response(r, 403)["error"] == "a seat may only schedule prompts for itself: you are ipsum-admin, the target is ipsum-orchestrator"
    assert count(ctx.user) == 0
  end

  test "an app token schedules for any seat, and must name it", ctx do
    assert %{"target" => "ipsum-orchestrator", "created_by" => "app"} =
             add(ctx.app, %{target: "ipsum-orchestrator"}) |> json_response(201) |> Map.fetch!("schedule")

    assert add(ctx.app, %{name: "other"}) |> json_response(422) |> Map.fetch!("error") =~ "target"
  end

  test "a seat without self is told to name itself", ctx do
    assert add(ctx.api, %{}) |> json_response(400) |> Map.fetch!("error") =~ "pass self"
  end

  test "a seat sees and manages only its own schedules", ctx do
    %{"id" => id} = add(ctx.app, %{target: "ipsum-orchestrator"}) |> json_response(201) |> Map.fetch!("schedule")
    add(ctx.api, %{self: "ipsum-admin", name: "mine"}) |> json_response(201)

    assert [%{"name" => "mine"}] = as(ctx.api) |> get("/api/schedules?self=ipsum-admin") |> json_response(200) |> Map.fetch!("schedules")
    assert as(ctx.api) |> get("/api/schedules?self=ipsum-admin&target=ipsum-orchestrator") |> json_response(403)

    for req <- [&get(&1, "/api/schedules/#{id}?self=ipsum-admin"),
                &get(&1, "/api/schedules/#{id}/runs?self=ipsum-admin"),
                &patch(&1, "/api/schedules/#{id}", %{self: "ipsum-admin", enabled: false}),
                &delete(&1, "/api/schedules/#{id}?self=ipsum-admin")] do
      assert req.(as(ctx.api)) |> json_response(403) |> Map.fetch!("error") =~ "targets ipsum-orchestrator"
    end

    # Nor can it move its own schedule to another seat.
    assert as(ctx.api) |> patch("/api/schedules/mine", %{self: "ipsum-admin", target: "ipsum-orchestrator"}) |> json_response(403)

    # The app sees both.
    assert length(as(ctx.app) |> get("/api/schedules") |> json_response(200) |> Map.fetch!("schedules")) == 2
  end

  test "pause, resume, edit and delete, by id or by name", ctx do
    add(ctx.api, %{self: "ipsum-admin"}) |> json_response(201)

    assert %{"enabled" => false} = as(ctx.api) |> patch("/api/schedules/weekly", %{self: "ipsum-admin", enabled: false}) |> json_response(200) |> Map.fetch!("schedule")
    assert %{"enabled" => true, "cron" => "0 9 * * 1"} =
             as(ctx.api) |> patch("/api/schedules/weekly", %{self: "ipsum-admin", enabled: true, cron: "0 9 * * 1"}) |> json_response(200) |> Map.fetch!("schedule")

    assert %{"runs" => []} = as(ctx.api) |> get("/api/schedules/weekly/runs?self=ipsum-admin") |> json_response(200)
    assert %{"deleted" => %{"name" => "weekly"}} = as(ctx.api) |> delete("/api/schedules/weekly?self=ipsum-admin") |> json_response(200)
    assert as(ctx.api) |> get("/api/schedules/weekly?self=ipsum-admin") |> json_response(404)
  end

  # --- 7. validation -------------------------------------------------------------

  test "a bad cron, a bad zone, an empty prompt or a taken name is a 422 naming the field", ctx do
    assert %{"cron" => [msg]} = add(ctx.api, %{self: "s", cron: "0 12 * *"}) |> json_response(422) |> Map.fetch!("errors")
    assert msg =~ "5 fields"
    assert %{"cron" => _} = add(ctx.api, %{self: "s", cron: "61 12 * * *"}) |> json_response(422) |> Map.fetch!("errors")
    assert %{"tz" => ["is not an IANA time zone (e.g. Europe/Oslo)"]} = add(ctx.api, %{self: "s", tz: "Europe/Osloo"}) |> json_response(422) |> Map.fetch!("errors")
    assert %{"prompt" => ["can't be blank"]} = add(ctx.api, %{self: "s", prompt: ""}) |> json_response(422) |> Map.fetch!("errors")
    assert %{"name" => _} = add(ctx.api, %{self: "s", name: "12"}) |> json_response(422) |> Map.fetch!("errors")

    add(ctx.api, %{self: "s"}) |> json_response(201)
    assert %{"name" => ["a schedule with this name exists"]} = add(ctx.api, %{self: "s"}) |> json_response(422) |> Map.fetch!("errors")
    assert count(ctx.user) == 1
  end

  # --- the prompt, exactly -------------------------------------------------------

  # Exactly n characters of mixed width: ASCII, Norwegian letters (2 bytes),
  # emoji (4 bytes), and line ends.
  defp text(n) do
    unit = String.codepoints("Hei på deg, Æøå! 🙂🚀\r\n\ttab  ")
    Stream.cycle(unit) |> Enum.take(n) |> Enum.join()
  end

  test "a 20,000-character prompt round-trips exactly", ctx do
    prompt = text(20_000)
    assert byte_size(prompt) > 20_000, "multi-byte: more bytes than characters"

    created = add(ctx.api, %{self: "s", prompt: prompt}) |> json_response(201) |> Map.fetch!("schedule")
    sha = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    assert %{"prompt_chars" => 20_000, "prompt_sha256" => ^sha} = created
    assert created["prompt_bytes"] == byte_size(prompt)
    assert created["prompt_preview"] == prompt |> String.codepoints() |> Enum.take(120) |> Enum.join()
    refute Map.has_key?(created, "prompt"), "a list does not carry the full text"

    shown = as(ctx.api) |> get("/api/schedules/#{created["id"]}?self=s") |> json_response(200) |> Map.fetch!("schedule")
    assert shown["prompt"] == prompt
    assert [%{"prompt" => ^prompt}] = as(ctx.api) |> get("/api/schedules?self=s&full=true") |> json_response(200) |> Map.fetch!("schedules")
  end

  test "20,001 characters is a 422 naming the limit and the length, and nothing is stored", ctx do
    r = add(ctx.api, %{self: "s", prompt: text(20_001)}) |> json_response(422)
    assert r["error"] == "prompt: is 20001 characters; the limit is 20000. Nothing was saved"
    assert count(ctx.user) == 0
  end

  test "an edit over the limit is refused and leaves the stored prompt as it was", ctx do
    add(ctx.api, %{self: "s", prompt: "short"}) |> json_response(201)
    assert as(ctx.api) |> patch("/api/schedules/weekly", %{self: "s", prompt: text(20_001)}) |> json_response(422)
    assert [%{prompt: "short"}] = Schedules.list(ctx.user.id)
  end
end
