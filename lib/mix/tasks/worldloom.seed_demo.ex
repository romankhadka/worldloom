defmodule Mix.Tasks.Worldloom.SeedDemo do
  use Mix.Task

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.Config

  @requirements ["app.config"]
  @shortdoc "Creates one deterministic hour of Worldloom demo signals"
  @event_count 120
  @sources [:wikimedia, :usgs, :open_meteo, :visitor]
  @visitor_kinds [:tug, :knot, :illuminate]

  @impl Mix.Task
  def run(_arguments) do
    disable_feed_startup()
    Mix.Task.run("app.start")

    demo_events = build_events(previous_hour_start(clock().()))
    existing_fingerprints = existing_fingerprints()

    created_count =
      Enum.reduce(demo_events, 0, fn event, count ->
        if MapSet.member?(existing_fingerprints, fingerprint(event)) do
          count
        else
          count + commit!(event)
        end
      end)

    if created_count == 0 do
      Mix.shell().info("Worldloom already has these 120 demo signals")
    else
      Mix.shell().info("Created #{created_count} deterministic demo signals")
    end
  end

  defp build_events(hour_start) do
    Enum.map(0..(@event_count - 1), fn index ->
      occurred_at = DateTime.add(hour_start, index * 30, :second)
      source = Enum.at(@sources, rem(index, length(@sources)))

      SourceEvent.new!(%{
        kind: kind(source, index),
        source: source,
        external_id: external_id(source, occurred_at),
        occurred_at: occurred_at,
        lane: lane(index),
        intensity: intensity(index),
        payload: payload(source, index)
      })
    end)
  end

  defp kind(:wikimedia, _index), do: :wikimedia
  defp kind(:usgs, _index), do: :earthquake
  defp kind(:open_meteo, _index), do: :weather
  defp kind(:visitor, index), do: Enum.at(@visitor_kinds, rem(div(index, 4), 3))

  defp external_id(:visitor, _occurred_at), do: nil

  defp external_id(source, occurred_at) do
    "worldloom-demo-#{source}-#{DateTime.to_unix(occurred_at, :second)}"
  end

  defp lane(index), do: (rem(index * 37, 91) + 5) / 100
  defp intensity(index), do: (rem(index * 29, 66) + 20) / 100

  defp payload(:wikimedia, index) do
    count = rem(index * 7, 18) + 3

    %{
      "summary" => "#{count} demo edits moved through the weave",
      "window_count" => 1,
      "window_span_seconds" => 4,
      "count" => count,
      "total_absolute_byte_delta" => count * 137,
      "language_buckets" => %{
        "current_1" => div(count + 1, 2),
        "current_2" => div(count, 2),
        "current_3" => 0,
        "current_4" => 0,
        "current_5" => 0
      },
      "edit_types" => demo_edit_types(index, count),
      "dominant_edit_type" => if(rem(index, 8) == 0, do: "new", else: "edit"),
      "truncated" => false
    }
  end

  defp payload(:usgs, index) do
    magnitude = Float.round(1.0 + rem(index * 11, 50) / 10, 1)

    %{
      "summary" => "Demo magnitude #{magnitude} movement beneath the fabric",
      "magnitude" => magnitude,
      "place" => "A deterministic demo location",
      "coordinates" => [-160.0 + rem(index * 13, 320), -70.0 + rem(index * 17, 140), 10.0]
    }
  end

  defp payload(:open_meteo, index) do
    low = -10.0 + rem(index * 3, 25)
    high = low + 12.0

    %{
      "summary" => "Demo weather moved softly across twelve cities",
      "temperature_range" => [low, high],
      "precipitation_coverage" => rem(index * 9, 100) / 100,
      "mean_wind" => 4.0 + rem(index * 5, 18),
      "day_night_ratio" => rem(index * 7, 100) / 100,
      "cities" => ["Vancouver", "Lagos", "Mumbai", "Tokyo"]
    }
  end

  defp payload(:visitor, index) do
    gesture = kind(:visitor, index)
    %{"summary" => "A demo visitor added a #{gesture} to the living edge"}
  end

  defp demo_edit_types(index, count) when rem(index, 8) == 0 do
    %{
      "categorize" => 0,
      "edit" => 0,
      "external" => 0,
      "log" => 0,
      "new" => count
    }
  end

  defp demo_edit_types(_index, count) do
    %{
      "categorize" => 0,
      "edit" => count,
      "external" => 0,
      "log" => 0,
      "new" => 0
    }
  end

  defp commit!(%SourceEvent{source: :visitor} = event) do
    nonce = "worldloom-demo-visitor-#{DateTime.to_unix(event.occurred_at, :second)}"

    case Coordinator.commit_visitor(event, nonce) do
      {:ok, _stored_event} -> 1
      {:error, reason} -> Mix.raise("could not create demo visitor signal: #{inspect(reason)}")
    end
  end

  defp commit!(event) do
    case Coordinator.commit_external([event], nil) do
      {:ok, [_stored_event]} -> 1
      {:ok, []} -> 0
      {:error, reason} -> Mix.raise("could not create demo source signal: #{inspect(reason)}")
    end
  end

  defp existing_fingerprints do
    600
    |> Store.latest()
    |> Enum.map(&fingerprint/1)
    |> MapSet.new()
  end

  defp fingerprint(event) do
    {
      to_string(event.source),
      to_string(event.kind),
      event.external_id,
      event.occurred_at,
      event.payload["summary"]
    }
  end

  defp previous_hour_start(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})
    |> DateTime.add(-1, :hour)
  end

  defp clock do
    :worldloom
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:clock, &DateTime.utc_now/0)
  end

  defp disable_feed_startup do
    signal_configuration = Application.fetch_env!(:worldloom, Worldloom.Signals)

    disabled_configuration =
      case signal_configuration do
        %Config{} = config -> %{config | enabled: false}
        config when is_list(config) -> Keyword.put(config, :enabled, false)
      end

    Application.put_env(
      :worldloom,
      Worldloom.Signals,
      disabled_configuration
    )
  end
end
