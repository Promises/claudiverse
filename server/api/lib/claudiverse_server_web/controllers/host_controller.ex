defmodule ClaudiverseServerWeb.HostController do
  @moduledoc """
  "New seat" from the operator's app (see Hosts).

  - `GET /api/hosts` — machines: online agents, hosts running seats, and
    every machine an agent has joined as, with `last_seen_at` (its agent's
    last join or leave) and `spawn`, what a spawn may ask for there (nil
    from an agent older than 0.13).
  - `GET /api/hosts/:host/recent_dirs` — past seats' working directories.
  - `GET /api/hosts/:host/ls?path=` — subfolders, answered by the agent.
  - `POST /api/hosts/:host/spawn` — APP TOKEN ONLY: start a seat; 202
    {spawn_id}, outcome as "host_spawn" on operator:events. {path, title,
    mode, prompt}, and where the machine's `spawn` offers them, `model` and
    `pooled`; asking a machine whose agent can't apply them is 409.
  - `POST /api/sessions/:id/stop` — APP TOKEN ONLY: the seat's machine closes
    its tmux session (the conversation stays on disk).
  - `POST /api/sessions/:id/resume` — APP TOKEN ONLY: start a stopped seat
    again with `claude --resume`; 202 {spawn_id}, outcome as "host_spawn"
    with op "resume" and "resumed_as", the row the running seat registered.
    The conversation is the row's conversation_id (set on a resumed seat's
    row, whose own claude_session_id is a placeholder), else its
    claude_session_id.

  SUPER TOKEN ONLY (the desktop, managing the machines):
  - `POST /api/hosts/:host/token` — mint a host token for a new machine
    named `host` (its agent's config); 201 {name, token}.
  - `POST /api/hosts/:host/roots` {path} — append a folder to that machine's
    whitelist. The MACHINE decides: its agent refuses (403 not_allowed)
    unless its own config has `allow_remote_roots: true`.
  - `DELETE /api/hosts/:host/roots` {path} — remove one; always allowed, as
    it only narrows what the machine offers.
  Both answer {roots} as the agent now has them.

  Stop and resume address the seat's tmux session by its title, so a seat
  renamed after it started is "not found" (404) rather than some other seat.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  import Ecto.Query

  alias ClaudiverseServer.{Hosts, Repo, Sessions}
  alias ClaudiverseServer.Sessions.Session

  # What Shift+Tab reaches on a normal seat; never bypassPermissions/dontAsk.
  @modes ~w(default acceptEdits plan auto)
  @title ~r/\A[A-Za-z0-9._-]{1,64}\z/
  # As the agent checks it: a model id or alias, with a [1m] suffix.
  @model ~r/\A[A-Za-z0-9._:\[\]-]{1,100}\z/
  @max_prompt 20_000

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    online = Map.new(Hosts.online(user_id))
    seen = Hosts.machines(user_id)

    running =
      from(s in Session,
        where: s.user_id == ^user_id and s.status == :running and not is_nil(s.host) and s.type != :proxy,
        group_by: s.host,
        select: {s.host, count(s.id)}
      )
      |> Repo.all()
      |> Map.new()

    hosts =
      (Map.keys(online) ++ Map.keys(running) ++ Map.keys(seen))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn name ->
        %{name: name, online: Map.has_key?(online, name), seats: Map.get(running, name, 0),
          roots: get_in(online, [name, :roots]) || [],
          remote_roots: get_in(online, [name, :remote_roots]) || false,
          version: get_in(online, [name, :version]),
          # What this machine's agent allows a profile to choose (its own
          # config): permission modes, runtime names (each with the Claude
          # Code build it pins), MCP catalog names. Empty for an agent older
          # than start_profile.
          modes: get_in(online, [name, :modes]) || [],
          runtimes: get_in(online, [name, :runtimes]) || [],
          mcp: get_in(online, [name, :mcp]) || [],
          spawn: get_in(online, [name, :spawn]),
          last_seen_at: Map.get(seen, name)}
      end)

    json(conn, %{hosts: hosts})
  end

  def recent_dirs(conn, %{"host" => host}) do
    user_id = conn.assigns.current_user.id

    dirs =
      from(s in Session,
        where: s.user_id == ^user_id and s.host == ^host and not is_nil(s.working_directory) and s.type != :proxy,
        group_by: s.working_directory,
        select: %{
          path: s.working_directory,
          last_used_at: max(s.updated_at),
          seats_running: sum(fragment("CASE WHEN ? = 'running' THEN 1 ELSE 0 END", s.status))
        },
        order_by: [desc: max(s.updated_at)],
        limit: 20
      )
      |> Repo.all()

    json(conn, %{dirs: dirs})
  end

  def ls(conn, %{"host" => host} = params) do
    path = if is_binary(params["path"]), do: params["path"], else: ""

    case Hosts.request(conn.assigns.current_user.id, host, "ls", %{"path" => path}) do
      {:ok, result} -> json(conn, result)
      {:error, code, message} -> agent_error(conn, code, message)
      {:error, :offline} -> conn |> put_status(:gateway_timeout) |> json(%{error: "host #{host} is offline"})
      {:error, :timeout} -> conn |> put_status(:gateway_timeout) |> json(%{error: "host #{host} did not answer"})
    end
  end

  def spawn(conn, %{"host" => host} = params) do
    mode = params["mode"] || "auto"
    title = params["title"]
    prompt = params["prompt"]
    model = if params["model"] in [nil, ""], do: nil, else: params["model"]
    pooled = params["pooled"]
    asked = Enum.reject([model && "model", is_boolean(pooled) && "pooled"], &(&1 in [nil, false]))

    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "spawning seats is app-only"})

      not (is_binary(params["path"]) and params["path"] != "") ->
        conn |> put_status(:bad_request) |> json(%{error: "path is required"})

      mode not in @modes ->
        conn |> put_status(:bad_request) |> json(%{error: "mode must be one of #{Enum.join(@modes, ", ")}"})

      not (is_nil(title) or (is_binary(title) and Regex.match?(@title, title))) ->
        conn |> put_status(:bad_request) |> json(%{error: "title must be 1-64 of A-Z a-z 0-9 . _ -"})

      not (is_nil(prompt) or (is_binary(prompt) and String.length(prompt) <= @max_prompt)) ->
        conn |> put_status(:bad_request) |> json(%{error: "prompt must be at most #{@max_prompt} characters"})

      not (is_nil(model) or (is_binary(model) and Regex.match?(@model, model))) ->
        conn |> put_status(:bad_request) |> json(%{error: "model must be a model name, like claude-haiku-4-5 or opus"})

      not (is_nil(pooled) or is_boolean(pooled)) ->
        conn |> put_status(:bad_request) |> json(%{error: "pooled must be true or false"})

      # An older agent would start the seat without them, silently.
      (missing = unoffered(conn.assigns.current_user.id, host, asked)) != [] ->
        conn |> put_status(:conflict)
        |> json(%{error: "#{host}'s host agent can't set #{Enum.join(missing, " or ")}: update it (run the installer again on #{host})"})

      true ->
        args = %{"path" => params["path"], "title" => title, "mode" => mode, "prompt" => prompt}
        args = if model, do: Map.put(args, "model", model), else: args
        args = if is_boolean(pooled), do: Map.put(args, "pooled", pooled), else: args

        case Hosts.spawn(conn.assigns.current_user.id, host, args) do
          {:ok, spawn_id} -> conn |> put_status(:accepted) |> json(%{spawn_id: spawn_id})
          {:error, :offline} -> conn |> put_status(:gateway_timeout) |> json(%{error: "host #{host} is offline"})
          {:error, :rate_limited} -> conn |> put_status(:too_many_requests) |> json(%{error: "one spawn per 10 s per host"})
        end
    end
  end

  def stop(conn, %{"id" => id}) do
    with :ok <- app_only(conn, "stopping seats is app-only"),
         {:ok, session} <- seat(conn, id),
         {:ok, title} <- resume_title(conn, session, nil) do
      case Hosts.request(conn.assigns.current_user.id, session.host, "stop", %{"title" => title}) do
        {:ok, _} ->
          :ok = ClaudiverseServer.Sessions.Room.ended_by_machine(session.id)
          json(conn, %{ok: true, host: session.host, title: title})
        {:error, code, message} -> agent_error(conn, code, message)
        {:error, reason} -> host_unreachable(conn, session.host, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  def resume(conn, %{"id" => id} = params) do
    with :ok <- app_only(conn, "resuming seats is app-only"),
         {:ok, session} <- seat(conn, id),
         :ok <- resumable(conn, session),
         {:ok, title} <- resume_title(conn, session, params["title"]),
         {:ok, mode} <- resume_mode(conn, session, params["mode"]) do
      args = %{"path" => session.working_directory, "title" => title, "mode" => mode,
               "session_id" => session.conversation_id || session.claude_session_id}

      case Hosts.resume(conn.assigns.current_user.id, session.host, args, session.id) do
        {:ok, spawn_id} -> conn |> put_status(:accepted) |> json(%{spawn_id: spawn_id})
        {:error, :rate_limited} -> conn |> put_status(:too_many_requests) |> json(%{error: "one spawn per 10 s per host"})
        {:error, reason} -> host_unreachable(conn, session.host, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  def mint_token(conn, %{"host" => host}) do
    with :ok <- super_only(conn) do
      case Accounts.create_host_token(conn.assigns.current_user, host) do
        {:ok, token} -> conn |> put_status(:created) |> json(%{name: host, token: token})
        {:error, :bad_host_name} -> conn |> put_status(:bad_request) |> json(%{error: "host name must be 1-128 of A-Z a-z 0-9 . _ -"})
      end
    else
      {:halt, conn} -> conn
    end
  end

  def add_root(conn, params), do: change_roots(conn, params, "add_root")
  def remove_root(conn, params), do: change_roots(conn, params, "remove_root")

  defp change_roots(conn, %{"host" => host} = params, op) do
    with :ok <- super_only(conn) do
      path = params["path"]

      if is_binary(path) and String.starts_with?(path, "/") do
        case Hosts.request(conn.assigns.current_user.id, host, op, %{"path" => path}) do
          {:ok, result} -> json(conn, result)
          {:error, code, message} -> agent_error(conn, code, message)
          {:error, reason} -> host_unreachable(conn, host, reason)
        end
      else
        conn |> put_status(:bad_request) |> json(%{error: "path must be an absolute folder path"})
      end
    else
      {:halt, conn} -> conn
    end
  end

  defp super_only(conn) do
    if Accounts.super_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: {:halt, conn |> put_status(:forbidden) |> json(%{error: "managing machines needs the super (desktop) token"})}
  end

  # Every seat carries the shared "api" token, so only the app's own token may
  # stop or start seats.
  # What of `asked` the host's online agent doesn't offer. An offline host
  # offers nothing to check against: the spawn is 504 anyway.
  defp unoffered(_user_id, _host, []), do: []

  defp unoffered(user_id, host, asked) do
    case List.keyfind(Hosts.online(user_id), host, 0) do
      nil -> []
      {_, meta} -> asked -- ((meta[:spawn] || %{})[:options] || [])
    end
  end

  defp app_only(conn, message) do
    if Accounts.app_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: {:halt, conn |> put_status(:forbidden) |> json(%{error: message})}
  end

  # The user's own seat, on a known machine (proxy rows are API mirrors, not seats).
  defp seat(conn, id) do
    case Integer.parse(to_string(id)) do
      {n, ""} ->
        case Sessions.get_user_session(conn.assigns.current_user.id, n) do
          %{type: type, host: host} = s when type != :proxy and is_binary(host) and host != "" -> {:ok, s}
          %{type: type} when type != :proxy -> halt(conn, :unprocessable_entity, "this seat did not report its machine")
          _ -> halt(conn, :not_found, "Not found")
        end

      _ ->
        halt(conn, :bad_request, "bad session id")
    end
  end

  defp resumable(conn, session) do
    cond do
      session.status == :running ->
        halt(conn, :conflict, "this seat is running; stop it first")

      not (is_binary(session.conversation_id || session.claude_session_id) and is_binary(session.working_directory)) ->
        halt(conn, :unprocessable_entity, "this seat did not report its Claude session and folder, so it cannot be resumed")

      true ->
        :ok
    end
  end

  # The title the app gave, else the seat's own (its tmux session name).
  defp resume_title(conn, session, nil) do
    if is_binary(session.title) and Regex.match?(@title, session.title),
      do: {:ok, session.title},
      else: halt(conn, :bad_request, "this seat's title is not a tmux seat name")
  end

  defp resume_title(conn, _session, title) do
    if is_binary(title) and Regex.match?(@title, title),
      do: {:ok, title},
      else: halt(conn, :bad_request, "title must be 1-64 of A-Z a-z 0-9 . _ -")
  end

  # The mode the app gave, else the seat's last mode if a normal one, else
  # auto, as a spawn and a new profile get.
  defp resume_mode(conn, session, nil),
    do: resume_mode(conn, session, if(session.permission_mode in @modes, do: session.permission_mode, else: "auto"))

  defp resume_mode(conn, _session, mode) do
    if mode in @modes,
      do: {:ok, mode},
      else: halt(conn, :bad_request, "mode must be one of #{Enum.join(@modes, ", ")}")
  end

  defp halt(conn, status, message), do: {:halt, conn |> put_status(status) |> json(%{error: message})}

  defp host_unreachable(conn, host, :offline), do: conn |> put_status(:gateway_timeout) |> json(%{error: "host #{host} is offline"})
  defp host_unreachable(conn, host, :timeout), do: conn |> put_status(:gateway_timeout) |> json(%{error: "host #{host} did not answer"})

  # The agent's refusal codes, as HTTP.
  defp agent_error(conn, code, message) do
    status =
      case code do
        "outside_roots" -> :forbidden
        "not_allowed" -> :forbidden
        "not_found" -> :not_found
        "bad_request" -> :bad_request
        "limit" -> :too_many_requests
        _ -> :bad_gateway
      end

    conn |> put_status(status) |> json(%{error: message, code: code})
  end
end
