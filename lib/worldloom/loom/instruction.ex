defmodule Worldloom.Loom.Instruction do
  alias Worldloom.Loom.Event

  @kind_source_pairs MapSet.new([
                       {"wikimedia", "wikimedia"},
                       {"earthquake", "usgs"},
                       {"weather", "open_meteo"},
                       {"tug", "visitor"},
                       {"knot", "visitor"},
                       {"illuminate", "visitor"},
                       {"public_activity", "bluesky"},
                       {"route_change", "ripe_ris"},
                       {"slot", "solana"},
                       {"randomness", "drand"}
                     ])
  @visual_keys ~w(spread bend pulse)

  @spec from_event(Event.t()) :: map()
  def from_event(%Event{} = event) do
    with :ok <- validate_event(event),
         {:ok, occurred_at} <- DateTime.shift_zone(event.occurred_at, "Etc/UTC"),
         {:ok, summary} <- fetch_summary(event.payload),
         {:ok, visual} <- fetch_visual(event.payload) do
      %{
        "sequence" => event.id,
        "kind" => event.kind,
        "source" => event.source,
        "occurred_at" => DateTime.to_iso8601(occurred_at),
        "render_version" => event.render_version,
        "seed" => event.render_seed,
        "lane" => event.lane,
        "intensity" => event.intensity,
        "visual" => visual,
        "summary" => summary
      }
    else
      _reason -> raise ArgumentError, "unsupported stored event: #{inspect(event.id)}"
    end
  end

  def from_event(_event), do: raise(ArgumentError, "expected a stored loom event")

  defp validate_event(event) do
    valid_pair? = MapSet.member?(@kind_source_pairs, {event.kind, event.source})

    if valid_pair? and is_integer(event.id) and event.id > 0 and
         is_struct(event.occurred_at, DateTime) and is_integer(event.render_version) and
         event.render_version > 0 and is_integer(event.render_seed) and event.render_seed >= 0 and
         event.render_seed < 2_147_483_647 and is_float(event.lane) and is_float(event.intensity) and
         is_map(event.payload) do
      :ok
    else
      :error
    end
  end

  defp fetch_summary(payload) do
    case Map.get(payload, "summary") do
      summary when is_binary(summary) -> {:ok, summary}
      _summary -> :error
    end
  end

  defp fetch_visual(payload) do
    case Map.get(payload, "visual") do
      visual when is_map(visual) -> {:ok, Map.take(visual, @visual_keys)}
      _visual -> :error
    end
  end
end
