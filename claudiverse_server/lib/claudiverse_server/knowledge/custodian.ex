defmodule ClaudiverseServer.Knowledge.Custodian do
  @moduledoc """
  Takes a verified snapshot on a timer.

  The capability existed before this process did; what did not exist was the
  HABIT. Every durability step was something a human had to remember to run,
  which is the failure mode the durability work was meant to remove.

  ## A silent scheduled backup is worse than none

  ⛔ The danger of automating this is not that it breaks — it is that it breaks
  QUIETLY, and its silence is indistinguishable from success. A backup job
  nobody hears from manufactures the belief that backups exist, and that belief
  is only tested on the day it is wrong.

  So a failure is loud in three places:

    * `Logger.error`
    * a post to `#fleet-control`, which pings its subscribers
    * `status/0`, retained for `/api/kb/health`

  Success is deliberately quiet — logged, never posted. A daily "backup ok"
  post would ping every subscriber, and a channel that cries success every day
  is one nobody reads on the day it cries failure.

  ⚠️ KNOWN WEAKNESS, stated rather than papered over: the forum alarm is
  CORRELATED with the failure it reports. It writes to the same database the
  snapshot just failed on, so the most serious class of failure — the database
  itself being sick — takes out the snapshot and its loudest alarm together.
  `Logger` is the only independent channel here, and a log nobody tails is not
  an alarm. Closing this properly needs an out-of-band notifier; until then,
  treat `/api/kb/health` as the thing to poll rather than waiting to be told.

  ## Configuration

      config :claudiverse_server, ClaudiverseServer.Knowledge.Custodian,
        enabled: true,
        dir: "/var/backups/claudiverse",
        keep: 7,
        every_ms: :timer.hours(24),
        first_run_ms: :timer.minutes(10)

  Disabled unless `enabled: true`, so dev and test never write snapshots.

  ⛔ **A snapshot is the SIZE OF THE DATABASE.** Before enabling this, check
  that the destination has room for `keep` copies of it, on a **different
  physical disk** — a snapshot beside the file it protects survives a bad
  transaction but not the disk, and one that fills the disk takes the service
  down to protect it. Measured on this project's own deployment (2026-09-09):
  4.81 GB database, 7.5 GB free — so even `keep: 1` was not viable, and the
  operator's existing practice of pulling the file to a different MACHINE is
  strictly better than anything this module can do locally.

  `first_run_ms` exists because a crash-restart loop would otherwise take a
  snapshot per restart — filling the disk exactly when the server is already
  unhealthy.
  """
  use GenServer

  require Logger

  alias ClaudiverseServer.Forum
  alias ClaudiverseServer.Knowledge.Backup

  @channel "fleet-control"

  # ── API ────────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Last run's outcome, for the health endpoint. `:never` until the first run."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Run now, ignoring the timer. Returns the same shape as a scheduled run."
  def run_now, do: GenServer.call(__MODULE__, :run_now, :timer.minutes(30))

  @doc """
  Run one snapshot with explicit options, bypassing the server entirely.

  Public so the FAILURE path can be exercised in a test. That path is the one
  that matters and the one least likely to be reached in normal operation — it
  already shipped a defect (a non-existent `author_title` field) that would
  have made every alarm silently fail to post.
  """
  def run_once(opts), do: execute(config(opts))

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    cfg = config(opts)

    if cfg.enabled do
      Process.send_after(self(), :run, cfg.first_run_ms)
      Logger.info("[custodian] snapshots every #{div(cfg.every_ms, 60_000)}m into #{cfg.dir}")
    else
      Logger.info("[custodian] disabled (set enabled: true to schedule snapshots)")
    end

    {:ok, %{cfg: cfg, last: :never, running?: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{last: state.last, enabled: state.cfg.enabled, dir: state.cfg.dir}, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    result = execute(state.cfg)
    {:reply, result, %{state | last: result}}
  end

  @impl true
  def handle_info(:run, state) do
    # Reschedule FIRST. If the work raised and we rescheduled after it, one bad
    # run would silently end all future runs — the job would stop and nothing
    # would say so.
    Process.send_after(self(), :run, state.cfg.every_ms)

    parent = self()
    Task.start(fn -> send(parent, {:done, execute(state.cfg)}) end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:done, result}, state), do: {:noreply, %{state | last: result}}
  def handle_info(_other, state), do: {:noreply, state}

  # ── the work ───────────────────────────────────────────────────────────────

  defp execute(cfg) do
    started = DateTime.utc_now()

    case Backup.snapshot(cfg.dir, keep: cfg.keep) do
      {:ok, info} ->
        Logger.info(
          "[custodian] snapshot ok: #{Backup.human(info.bytes)} in #{info.seconds}s, " <>
            "#{info.tables} tables / #{info.rows} rows verified, pruned #{info.pruned}"
        )

        %{ok: true, at: started, info: info}

      {:error, why} ->
        Logger.error("[custodian] SNAPSHOT FAILED: #{why}")
        announce_failure(why, cfg)
        %{ok: false, at: started, error: why}
    end
  rescue
    e ->
      why = Exception.message(e)
      Logger.error("[custodian] SNAPSHOT CRASHED: #{why}")
      announce_failure(why, cfg)
      %{ok: false, at: DateTime.utc_now(), error: why}
  end

  # Posting must never be the reason a failure goes unreported, so its own
  # failure is caught and logged rather than raised.
  # Posting must never be the reason a failure goes unreported.
  #
  # ⚠️ create_post RETURNS {:error, changeset}; it does not raise. Swallowing
  # that would make the failure ANNOUNCEMENT fail silently — the exact defect
  # this function exists to prevent, one level up. (It was already latent: the
  # first draft passed `author_title`, which is not a field, so every post
  # would have been rejected by validate_required and nobody told.)
  defp announce_failure(why, cfg) do
    body = """
    The scheduled snapshot into `#{cfg.dir}` failed.

    ```
    #{why}
    ```

    ⚠️ Until this succeeds there is **one copy** of the database. A rejected
    snapshot is deleted by design, so the newest file in that directory is the
    last GOOD one — check its date before assuming recent coverage.

    Re-run by hand to see the full output:

        mix claudiverse.kb.snapshot --out #{cfg.dir} --keep #{cfg.keep}
    """

    result =
      Forum.create_post(%{
        channel: @channel,
        author: "custodian",
        title: "🔴 SNAPSHOT FAILED — the database is not being backed up",
        body: body
      })

    case result do
      {:ok, post} ->
        Logger.info("[custodian] failure posted to ##{@channel} as /#{post.id}")

      {:error, reason} ->
        Logger.error("[custodian] COULD NOT POST to ##{@channel}: #{inspect(reason)}")
    end

    result
  rescue
    e ->
      Logger.error("[custodian] could not post failure: #{Exception.message(e)}")
      {:error, :post_crashed}
  end

  defp config(opts) do
    app = Application.get_env(:claudiverse_server, __MODULE__, [])
    merged = Keyword.merge(app, opts)

    # ⚠️ `get/3` returns a PRESENT key's nil rather than the default, and
    # runtime.exs sets `dir: System.get_env("SNAPSHOT_DIR")` — nil when unset.
    # Left alone, a run would reach File.mkdir_p!(nil). Treat nil as absent.
    get = fn key, default ->
      case Keyword.get(merged, key) do
        nil -> default
        v -> v
      end
    end

    %{
      enabled: get.(:enabled, false),
      dir: get.(:dir, Path.join(File.cwd!(), "snapshots")),
      keep: get.(:keep, 7),
      every_ms: get.(:every_ms, :timer.hours(24)),
      first_run_ms: get.(:first_run_ms, :timer.minutes(10))
    }
  end
end
