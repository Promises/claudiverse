defmodule ClaudiverseServer.Sessions.NdjsonParser do
  @moduledoc """
  Parses newline-delimited JSON (NDJSON) from a binary stream.
  Accumulates partial lines and yields complete JSON objects.
  """

  defstruct buffer: ""

  def new, do: %__MODULE__{}

  @doc """
  Feed data into the parser. Returns {parsed_messages, updated_parser}.
  """
  def feed(%__MODULE__{buffer: buffer} = parser, data) when is_binary(data) do
    combined = buffer <> data
    lines = String.split(combined, "\n")

    # Last element is either empty (if data ended with \n) or a partial line
    {complete_lines, [remainder]} = Enum.split(lines, -1)

    messages =
      complete_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, parsed} -> [parsed | acc]
          {:error, _} -> acc
        end
      end)
      |> Enum.reverse()

    {messages, %{parser | buffer: remainder}}
  end
end
