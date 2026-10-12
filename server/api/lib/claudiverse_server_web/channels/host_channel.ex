defmodule ClaudiverseServerWeb.HostChannel do
  @moduledoc """
  `host:<name>` — a machine's host agent (see Hosts). Only that host's own
  token (context "host:<name>") may join it: a seat's shared token, the app
  token, or another host's token is refused.

  Join payload: %{"roots" => [path], "version" => string, "remote_roots" => bool}
  (remote_roots: whether this machine accepts whitelist additions from the
  desktop; the agent enforces it, this only lets the app show the option),
  and from agents with `start_profile`: "modes" [mode], "runtimes" [%{"name",
  "version"}], "mcp" [catalog name] — the choices a profile may make there.
  From 0.13: "spawn" %{"options" [model|pooled], "pool_only", "pooled"},
  what a plain spawn may ask for there (nil from an older agent).
  Server -> agent: "request" %{"request_id", "op", "args"}.
  Agent -> server: "reply" %{"request_id", "ok", "result" | "code", "error"}.
  """
  use Phoenix.Channel

  import Ecto.Query

  alias ClaudiverseServer.{Hosts, Repo}
  alias ClaudiverseServer.Sessions.{Room, Session}

  @modes ~w(default acceptEdits plan auto)

  @impl true
  def join("host:" <> name, params, socket) do
    if socket.assigns[:token_context] == "host:" <> name do
      meta = %{
        roots: for(r <- List.wrap(params["roots"]), is_binary(r), do: r),
        version: if(is_binary(params["version"]), do: params["version"], else: nil),
        remote_roots: params["remote_roots"] == true,
        modes: for(m <- List.wrap(params["modes"]), is_binary(m), do: m),
        runtimes: for(%{"name" => n} = r <- List.wrap(params["runtimes"]), is_binary(n), do: %{name: n, version: r["version"]}),
        mcp: for(m <- List.wrap(params["mcp"]), is_binary(m), do: m),
        spawn: spawn_choices(params["spawn"]),
        ip: socket.assigns[:peer_ip]
      }

      :ok = Hosts.register(socket.assigns.current_user.id, name, meta)
      Hosts.seen(socket.assigns.current_user.id, name, true)
      Hosts.place_waiting(socket.assigns.current_user.id, meta.ip)
      # After the join completes, so the agent can be asked to start seats.
      send(self(), :autostart)
      # The seats that live on the machine now (agent 0.12+): a profile whose
      # row reads running with none there is a leftover. nil from an older
      # agent, or one that could not ask tmux.
      live = if is_list(params["live_seats"]), do: for(t <- params["live_seats"], is_binary(t), do: t)
      {:ok, socket |> assign(:host_name, name) |> assign(:live_seats, live)}
    else
      {:error, %{reason: "this token may not join host:#{name}"}}
    end
  end

  @impl true
  def handle_in("reply", %{"request_id" => rid} = payload, socket) when is_binary(rid) do
    Hosts.reply(rid, payload)
    {:noreply, socket}
  end

  # The modes the machine's seats are in, read from their footers by the agent
  # (0.9.3+), as {title => mode}: a mod seat reports none itself. Only this
  # machine's running seats are touched, by exact title.
  def handle_in("seat_modes", %{"modes" => modes}, socket) when is_map(modes) do
    user_id = socket.assigns.current_user.id
    host = socket.assigns[:host_name]
    valid = for {title, mode} <- modes, is_binary(title) and mode in @modes, into: %{}, do: {title, mode}

    if host && valid != %{} do
      from(s in Session,
        where: s.user_id == ^user_id and s.host == ^host and s.status == :running and s.type != :proxy and s.title in ^Map.keys(valid),
        select: {s.id, s.title}
      )
      |> Repo.all()
      |> Enum.each(fn {id, title} -> Room.report_permission_mode(id, valid[title]) end)
    end

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # The machine is online: start its autostart profiles (Profiles.autostart/2),
  # in a task, as starts are spaced by the per-machine start interval.
  @impl true
  def handle_info(:autostart, socket) do
    user_id = socket.assigns.current_user.id
    name = socket.assigns.host_name
    live = socket.assigns[:live_seats]
    Task.start(fn -> ClaudiverseServer.Profiles.autostart(user_id, name, live) end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:host_request, rid, op, args}, socket) do
    push(socket, "request", %{"request_id" => rid, "op" => op, "args" => args})
    {:noreply, socket}
  end

  # A newer connection for this host took over.
  def handle_info(:host_replaced, socket), do: {:stop, :normal, assign(socket, :replaced, true)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The agent left: when it was last here. Not when a newer connection of the
  # same machine replaced this one: that one is online.
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:host_name] && !socket.assigns[:replaced] do
      Hosts.seen(socket.assigns.current_user.id, socket.assigns.host_name, false)
    end

    :ok
  end

  @spawn_options ~w(model pooled)
  defp spawn_choices(%{"options" => options} = s) when is_list(options) do
    %{options: Enum.filter(options, &(&1 in @spawn_options)), pool_only: s["pool_only"] == true, pooled: s["pooled"] == true}
  end

  defp spawn_choices(_), do: nil
end
