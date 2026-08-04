defmodule Worldloom.Signals.WeatherWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Signals.WeatherWorker

  @fixture "test/support/fixtures/feeds/open_meteo.json"
  @now ~U[2026-08-03 12:30:00.000000Z]

  test "requests all twelve fixed anchors in order and submits one ambient event" do
    attach_feed_telemetry()
    test_process = self()
    body = @fixture |> File.read!() |> Jason.decode!()
    twelve_responses = Stream.cycle(body) |> Enum.take(12)

    client = fn url, options ->
      send(test_process, {:request, url, options})
      {:ok, %{status: 200, body: twelve_responses, etag: nil}}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    worker = start_worker(client: client, buffer: buffer)

    assert_receive {:request, "https://example.test/weather", options}, 500
    assert options[:params][:timezone] == "UTC"
    assert options[:params][:current] == "temperature_2m,precipitation,wind_speed_10m,is_day"
    assert String.split(options[:params][:latitude], ",") |> length() == 12
    assert String.split(options[:params][:longitude], ",") |> length() == 12

    assert Enum.map(WeatherWorker.anchors(), & &1.label) == [
             "Vancouver",
             "Mexico City",
             "São Paulo",
             "Reykjavík",
             "London",
             "Lagos",
             "Nairobi",
             "Cape Town",
             "Mumbai",
             "Singapore",
             "Tokyo",
             "Sydney"
           ]

    assert_receive {:submission, [event], checkpoint}, 500
    assert event.source == :open_meteo
    assert event.payload["cities"] == Enum.map(WeatherWorker.anchors(), & &1.label)
    assert checkpoint.source == "open_meteo"
    assert checkpoint.last_successful_at == @now
    assert checkpoint.metadata["observation_at"] == "2026-08-03T12:00:00.000000Z"
    assert_receive {:timer, ^worker, :poll, 600_000}, 500

    assert_receive {:feed_telemetry, %{count: 1, duration: duration},
                    %{source: :open_meteo, status: :success, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0
  end

  test "malformed weather never reaches the buffer" do
    attach_feed_telemetry()
    test_process = self()
    client = fn _url, _options -> {:ok, %{status: 200, body: [%{}], etag: nil}} end
    buffer = fn _events, _checkpoint -> send(test_process, :unexpected_submission) end
    worker = start_worker(client: client, buffer: buffer)

    refute_receive :unexpected_submission, 100
    assert_receive {:timer, ^worker, :poll, 600_000}, 500

    assert_receive {:feed_telemetry, %{count: 0, duration: duration},
                    %{source: :open_meteo, status: :failure, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0
  end

  defp attach_feed_telemetry do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :signals, :feed],
        fn _event, measurements, metadata, test_process ->
          send(test_process, {:feed_telemetry, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_worker(overrides) do
    test_process = self()

    timer = fn process, message, delay ->
      send(test_process, {:timer, process, message, delay})
      make_ref()
    end

    options =
      Keyword.merge(
        [
          name: nil,
          url: "https://example.test/weather",
          interval_ms: 600_000,
          clock: fn -> @now end,
          timer: timer
        ],
        overrides
      )

    {:ok, worker} = WeatherWorker.start_link(options)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    worker
  end
end
