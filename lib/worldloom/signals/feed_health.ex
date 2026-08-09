defmodule Worldloom.Signals.FeedHealth do
  @stream_live_seconds 20
  @drand_live_seconds 12
  @usgs_live_seconds 3 * 60
  @weather_live_seconds 30 * 60

  @type state :: :live | :quiet | :stale | :disconnected
  @type source_health :: %{state: state(), observed_at: DateTime.t() | nil}
  @type observation :: %{
          optional(:connection) => :connected | :disconnected,
          optional(:last_contact_at) => DateTime.t() | nil,
          optional(:last_activity_at) => DateTime.t() | nil
        }
  @type observed_source :: :wikimedia | :bluesky | :ripe_ris | :solana | :drand
  @type inputs :: %{
          observations: %{optional(observed_source()) => observation()},
          checkpoints: [map()]
        }
  @type projection :: %{
          wikimedia: source_health(),
          bluesky: source_health(),
          ripe_ris: source_health(),
          solana: source_health(),
          drand: source_health(),
          usgs: source_health(),
          open_meteo: source_health()
        }

  @spec project(inputs(), DateTime.t()) :: projection()
  def project(%{observations: observations, checkpoints: checkpoints}, %DateTime{} = now)
      when is_map(observations) and is_list(checkpoints) do
    checkpoints_by_source =
      Map.new(checkpoints, fn checkpoint -> {field(checkpoint, :source), checkpoint} end)

    usgs_observed_at =
      checkpoints_by_source |> Map.get("usgs") |> field(:last_successful_at)

    weather_observed_at =
      checkpoints_by_source |> Map.get("open_meteo") |> field(:last_successful_at)

    %{
      wikimedia: stream_health(observations, :wikimedia, now),
      bluesky: stream_health(observations, :bluesky, now),
      ripe_ris: stream_health(observations, :ripe_ris, now),
      solana: stream_health(observations, :solana, now),
      drand: drand_health(observations, now),
      usgs: freshness(usgs_observed_at, now, @usgs_live_seconds, :live, :quiet),
      open_meteo: freshness(weather_observed_at, now, @weather_live_seconds, :live, :stale)
    }
  end

  defp stream_health(observations, source, now) do
    observation = Map.get(observations, source, %{})
    activity_at = field(observation, :last_activity_at)

    if field(observation, :connection) == :connected do
      freshness(activity_at, now, @stream_live_seconds, :live, :quiet)
    else
      %{state: :disconnected, observed_at: valid_time(activity_at)}
    end
  end

  defp drand_health(observations, now) do
    activity_at = observations |> Map.get(:drand, %{}) |> field(:last_activity_at)
    freshness(activity_at, now, @drand_live_seconds, :live, :stale)
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

  defp valid_time(%DateTime{} = observed_at), do: observed_at
  defp valid_time(_observed_at), do: nil

  defp field(nil, _key), do: nil
  defp field(container, key) when is_map(container), do: Map.get(container, key)
  defp field(_container, _key), do: nil
end
