defmodule Worldloom.Signals.SSEParser do
  @maximum_bytes 256 * 1024

  @type frame :: %{id: binary() | nil, event: binary() | nil, data: binary()}

  @spec push(binary(), binary()) :: {[frame()], binary()}
  def push(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    combined = buffer <> chunk
    validate_incremental_utf8!(combined)

    normalized = :binary.replace(combined, "\r\n", "\n", [:global])
    parts = :binary.split(normalized, "\n\n", [:global])
    remaining = List.last(parts)
    complete_frames = Enum.drop(parts, -1)

    validate_size!(remaining, "incomplete SSE buffer")

    frames =
      complete_frames
      |> Enum.flat_map(fn encoded_frame ->
        validate_size!(encoded_frame, "SSE frame")

        case parse_frame(encoded_frame) do
          nil -> []
          frame -> [frame]
        end
      end)

    {frames, remaining}
  end

  def push(_buffer, _chunk), do: raise(ArgumentError, "SSE input must be binary")

  defp parse_frame(""), do: nil

  defp parse_frame(encoded_frame) do
    parsed =
      encoded_frame
      |> :binary.split("\n", [:global])
      |> Enum.reduce(%{id: nil, event: nil, data: [], data?: false}, &parse_line/2)

    if parsed.data? do
      %{
        id: parsed.id,
        event: parsed.event,
        data: parsed.data |> Enum.reverse() |> Enum.join("\n")
      }
    end
  end

  defp parse_line(<<":", _comment::binary>>, parsed), do: parsed

  defp parse_line(line, parsed) do
    {field, raw_value} = split_field(line)
    value = trim_optional_space(raw_value)

    case field do
      "data" -> %{parsed | data: [value | parsed.data], data?: true}
      "id" -> if :binary.match(value, <<0>>) == :nomatch, do: %{parsed | id: value}, else: parsed
      "event" -> %{parsed | event: empty_to_nil(value)}
      _unknown -> parsed
    end
  end

  defp split_field(line) do
    case :binary.match(line, ":") do
      {position, 1} ->
        <<field::binary-size(^position), ?:, value::binary>> = line
        {field, value}

      :nomatch ->
        {line, ""}
    end
  end

  defp trim_optional_space(<<" ", value::binary>>), do: value
  defp trim_optional_space(value), do: value

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp validate_incremental_utf8!(binary) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) -> :ok
      {:incomplete, _valid_prefix, trailing_bytes} when byte_size(trailing_bytes) <= 3 -> :ok
      {:incomplete, _valid_prefix, _trailing_bytes} -> invalid_utf8!()
      {:error, _valid_prefix, _invalid_bytes} -> invalid_utf8!()
    end
  end

  defp validate_size!(binary, _description) when byte_size(binary) <= @maximum_bytes, do: :ok

  defp validate_size!(_binary, description) do
    raise ArgumentError, "#{description} exceeds 256 KB"
  end

  defp invalid_utf8!, do: raise(ArgumentError, "SSE stream contains malformed UTF-8")
end
