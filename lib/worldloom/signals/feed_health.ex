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
  @type observed_source ::
          :wikimedia | :bluesky | :ripe_ris | :solana | :drand | :usgs | :open_meteo
  @type inputs :: %{
          observations: %{optional(observed_source()) => observation()}
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
  def project(%{observations: observations}, %DateTime{} = now) when is_map(observations) do
    %{
      wikimedia: stream_health(observations, :wikimedia, now),
      bluesky: stream_health(observations, :bluesky, now),
      ripe_ris: stream_health(observations, :ripe_ris, now),
      solana: stream_health(observations, :solana, now),
      drand: drand_health(observations, now),
      usgs: polling_health(observations, :usgs, now, @usgs_live_seconds, :quiet),
      open_meteo: polling_health(observations, :open_meteo, now, @weather_live_seconds, :stale)
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

  defp polling_health(observations, source, now, threshold, expired_state) do
    contact_at = observations |> Map.get(source, %{}) |> field(:last_contact_at)
    freshness(contact_at, now, threshold, :live, expired_state)
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
