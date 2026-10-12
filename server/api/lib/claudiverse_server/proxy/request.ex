defmodule ClaudiverseServer.Proxy.Request do
  @moduledoc """
  Pure functions over one proxied Anthropic API exchange: where it goes, what
  kind of request it is, whose account it uses, and what the model answered.

  Kept free of processes and I/O so every rule here is unit-testable, and so
  the request path in `ClaudiverseServerWeb.ProxyPlug` never depends on them
  succeeding: a parse failure costs an observation, never a request.
  """

  @doc """
  `["seat", "lorem-w1", "v1", "messages"]` → `{"lorem-w1", "/v1/messages"}`.
  Without a seat segment the seat comes from `x-claudiverse-seat`, else nil.
  """
  def route(["seat", seat | rest], _headers), do: {URI.decode(seat), "/" <> Enum.join(rest, "/")}
  def route(parts, headers), do: {header(headers, "x-claudiverse-seat"), "/" <> Enum.join(parts, "/")}

  @doc """
  main | subagent | auxiliary | compaction | workflow | probe.

  Upstream's own label comes first: with `CLAUDE_CODE_GATEWAY_HINT_HEADERS`
  set, Claude Code sends `x-claude-code-request-class` from the same classifier
  patch 002's `isConversation()` copies. The body heuristics below are only the
  fallback for a seat launched without it — measured on 2.1.286: the main
  thread sends ~110 tools, session titling and prompt suggestion send none, and
  the startup quota probe asks for one token.
  """
  def classify(headers, body) do
    case header(headers, "x-claude-code-request-class") do
      hinted when hinted not in [nil, ""] -> hinted
      _ -> classify_by_shape(headers, body)
    end
  end

  defp classify_by_shape(headers, body) do
    cond do
      header(headers, "x-claude-code-agent-id") not in [nil, ""] -> "subagent"
      not is_map(body) -> "auxiliary"
      body["max_tokens"] == 1 -> "probe"
      not (is_list(body["tools"]) and body["tools"] != []) -> "auxiliary"
      true -> "main"
    end
  end

  @doc """
  Whether a model request is the main loop's own (a turn's call or its
  compaction), the calls whose failure ends a turn: not a subagent's, nor a
  session title, a prompt suggestion or the startup quota probe. Read without
  decoding the body, which is on the request's path: upstream's
  `x-claude-code-request-class` when the seat sends it, else whether the body
  carries tools (the main loop sends ~110; titling, suggestions and the probe
  send none). Claude Code writes JSON without spaces, and a `"` inside a string
  value is escaped, so `"tools":[{` is a key of the request itself.
  """
  def main_loop?(headers, body) do
    hint = header(headers, "x-claude-code-request-class")

    cond do
      header(headers, "x-claude-code-agent-id") not in [nil, ""] -> false
      hint not in [nil, ""] -> hint in ["main", "compaction"]
      true -> :binary.match(body, ~s("tools":[{)) != :nomatch
    end
  end

  @doc "The account a request is billed to, from `metadata.user_id` (a JSON string)."
  def account(%{"metadata" => %{"user_id" => uid}}) when is_binary(uid) do
    case Jason.decode(uid) do
      {:ok, %{"account_uuid" => a}} when is_binary(a) -> a
      _ -> nil
    end
  end

  def account(_), do: nil

  @doc "Rebuild the assistant message from an SSE stream or a plain JSON body."
  def assistant(content_type, raw) when is_binary(raw) and raw != "" do
    if String.contains?(content_type || "", "event-stream"),
      do: from_sse(raw),
      else: from_json(raw)
  end

  def assistant(_, _), do: nil

  defp from_json(raw) do
    case Jason.decode(raw) do
      {:ok, %{"type" => "message"} = m} -> m
      _ -> nil
    end
  end

  defp from_sse(raw) do
    {msg, blocks} =
      raw
      |> String.split("\n")
      |> Enum.reduce({nil, %{}}, fn line, acc ->
        with "data: " <> json <- line,
             {:ok, ev} <- Jason.decode(json) do
          sse_event(ev, acc)
        else
          _ -> acc
        end
      end)

    if msg do
      content =
        blocks
        |> Enum.sort_by(fn {i, _} -> i end)
        |> Enum.map(fn {_, b} -> finish_block(b) end)

      Map.put(msg, "content", content)
    end
  end

  defp sse_event(%{"type" => "message_start", "message" => m}, {_, blocks}), do: {m, blocks}

  defp sse_event(%{"type" => "content_block_start", "index" => i, "content_block" => b}, {m, blocks}),
    do: {m, Map.put(blocks, i, Map.put(b, "_json", ""))}

  defp sse_event(%{"type" => "content_block_delta", "index" => i, "delta" => d}, {m, blocks}) do
    case blocks do
      %{^i => b} -> {m, Map.put(blocks, i, apply_delta(b, d))}
      _ -> {m, blocks}
    end
  end

  defp sse_event(%{"type" => "message_delta"} = ev, {m, blocks}) when is_map(m) do
    m =
      m
      |> Map.put("stop_reason", get_in(ev, ["delta", "stop_reason"]) || m["stop_reason"])
      |> Map.put("usage", Map.merge(m["usage"] || %{}, ev["usage"] || %{}))

    {m, blocks}
  end

  defp sse_event(_, acc), do: acc

  defp apply_delta(b, %{"type" => "text_delta", "text" => t}), do: Map.update(b, "text", t, &(&1 <> t))
  defp apply_delta(b, %{"type" => "thinking_delta", "thinking" => t}), do: Map.update(b, "thinking", t, &(&1 <> t))
  defp apply_delta(b, %{"type" => "signature_delta", "signature" => s}), do: Map.put(b, "signature", s)
  defp apply_delta(b, %{"type" => "input_json_delta", "partial_json" => j}), do: Map.update!(b, "_json", &(&1 <> j))
  defp apply_delta(b, _), do: b

  defp finish_block(%{"_json" => ""} = b), do: Map.delete(b, "_json")

  defp finish_block(%{"_json" => json} = b) do
    b = Map.delete(b, "_json")

    case Jason.decode(json) do
      {:ok, input} -> Map.put(b, "input", input)
      _ -> Map.put(b, "input_raw", json)
    end
  end

  defp finish_block(b), do: b

  @doc "The `anthropic-ratelimit-unified-*` response headers, as a map."
  def ratelimit(headers) do
    for {k, v} <- headers, String.starts_with?(k, "anthropic-ratelimit-unified"), into: %{}, do: {k, v}
  end

  @doc "First value of a (lower-case) header in a Plug/Mint header list."
  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
