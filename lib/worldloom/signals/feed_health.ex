defmodule Worldloom.Signals.FeedHealth do
  @wikimedia_live_seconds 60
  @usgs_live_seconds 3 * 60
  @weather_live_seconds 30 * 60

  @type state :: :live | :quiet | :stale
  @type source_health :: %{state: state(), observed_at: DateTime.t() | nil}
  @type projection :: %{
          wikimedia: source_health(),
          usgs: source_health(),
          open_meteo: source_health()
        }

  @spec project([map()], DateTime.t()) :: projection()
  def project(checkpoints, %DateTime{} = now) when is_list(checkpoints) do
    checkpoints_by_source =
      Map.new(checkpoints, fn checkpoint -> {field(checkpoint, :source), checkpoint} end)

    wikimedia_observed_at =
      checkpoints_by_source
      |> Map.get("wikimedia")
      |> metadata_time("last_event_at")

    usgs_observed_at =
      checkpoints_by_source |> Map.get("usgs") |> field(:last_successful_at)

    weather_observed_at =
      checkpoints_by_source |> Map.get("open_meteo") |> field(:last_successful_at)

    %{
      wikimedia: freshness(wikimedia_observed_at, now, @wikimedia_live_seconds, :live, :quiet),
      usgs: freshness(usgs_observed_at, now, @usgs_live_seconds, :live, :quiet),
      open_meteo: freshness(weather_observed_at, now, @weather_live_seconds, :live, :stale)
    }
  end

  defp freshness(%DateTime{} = observed_at, now, threshold, fresh_state, expired_state) do
    state =
      if DateTime.compare(observed_at, DateTime.add(now, -threshold, :second)) in [:eq, :gt] do
        fresh_state
      else
        expired_state
      end

    %{state: state, observed_at: observed_at}
  end

  defp freshness(_observed_at, _now, _threshold, _fresh_state, expired_state),
    do: %{state: expired_state, observed_at: nil}

  defp metadata_time(nil, _key), do: nil

  defp metadata_time(checkpoint, key) do
    case checkpoint |> field(:metadata) |> then(&(is_map(&1) && Map.get(&1, key))) do
      encoded_time when is_binary(encoded_time) ->
        case DateTime.from_iso8601(encoded_time) do
          {:ok, observed_at, _offset} -> observed_at
          {:error, _reason} -> nil
        end

      _missing_or_invalid ->
        nil
    end
  end

  defp field(nil, _key), do: nil
  defp field(container, key), do: Map.get(container, key)
end
