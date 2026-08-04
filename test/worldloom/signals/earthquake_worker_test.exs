defmodule Worldloom.Signals.EarthquakeWorkerTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Signals.EarthquakeWorker

  @fixture "test/support/fixtures/feeds/usgs.json"
  @now ~U[2026-08-03 12:30:00.000000Z]

  test "polls immediately, submits normalized events, and saves the response ETag in the checkpoint" do
    attach_feed_telemetry()
    test_process = self()
    body = read_fixture()

    client = fn url, options ->
      send(test_process, {:request, url, options})
      {:ok, %{status: 200, body: body, etag: ~s("quake-etag")}}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint})
      :ok
    end

    worker = start_worker(client: client, buffer: buffer)

    assert_receive {:request, "https://example.test/usgs", options}, 500
    assert options[:etag] == nil

    assert_receive {:submission, events, checkpoint}, 500
    assert length(events) == 3
    assert checkpoint.source == "usgs"
    assert checkpoint.etag == ~s("quake-etag")
    assert checkpoint.last_successful_at == @now
    assert checkpoint.metadata["generated_at"] == body["metadata"]["generated"]
    assert_receive {:timer, ^worker, :poll, 60_000}, 500

    assert_receive {:feed_telemetry, %{count: 3, duration: duration},
                    %{source: :usgs, status: :success, attempt: 0}},
                   500

    assert is_integer(duration) and duration >= 0
  end

  test "restores ETag, treats 304 as successful contact, and never writes the checkpoint itself" do
    insert_checkpoint("usgs", %{
      etag: ~s("saved-etag"),
      metadata: %{"generated_at" => 1_754_224_200_000}
    })

    test_process = self()

    client = fn _url, options ->
      send(test_process, {:request_options, options})
      {:ok, %{status: 304, body: "", etag: ~s("saved-etag")}}
    end

    buffer = fn events, checkpoint ->
      send(test_process, {:submission, events, checkpoint, self()})

      receive do
        :release_submission -> :ok
      end
    end

    worker = start_worker(client: client, buffer: buffer)

    assert_receive {:request_options, options}, 500
    assert options[:etag] == ~s("saved-etag")
    assert_receive {:submission, [], checkpoint, blocked_worker}, 500
    persisted_contact = Repo.get!(FeedCheckpoint, "usgs").last_successful_at
    assert DateTime.compare(persisted_contact, ~U[2026-08-03 11:00:00Z]) == :eq
    send(blocked_worker, :release_submission)
    assert checkpoint.last_successful_at == @now
    assert checkpoint.metadata == %{"generated_at" => 1_754_224_200_000}
    assert_receive {:timer, ^worker, :poll, 60_000}, 500
  end

  test "malformed bodies do not submit or move the restored ETag" do
    attach_feed_telemetry()
    insert_checkpoint("usgs", %{etag: ~s("saved-etag")})
    test_process = self()

    client = fn _url, _options ->
      {:ok, %{status: 200, body: %{"features" => "bad"}, etag: ~s("new")}}
    end

    buffer = fn _events, _checkpoint -> send(test_process, :unexpected_submission) end
    worker = start_worker(client: client, buffer: buffer)

    refute_receive :unexpected_submission, 100
    assert_receive {:timer, ^worker, :poll, 60_000}, 500
    assert Repo.get!(FeedCheckpoint, "usgs").etag == ~s("saved-etag")

    assert_receive {:feed_telemetry, %{count: 0, duration: duration},
                    %{source: :usgs, status: :failure, attempt: 0}},
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
          url: "https://example.test/usgs",
          interval_ms: 60_000,
          clock: fn -> @now end,
          timer: timer
        ],
        overrides
      )

    {:ok, worker} = EarthquakeWorker.start_link(options)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)
    worker
  end

  defp insert_checkpoint(source, overrides) do
    attributes =
      Map.merge(
        %{
          source: source,
          cursor: nil,
          etag: nil,
          last_successful_at: ~U[2026-08-03 11:00:00Z],
          metadata: %{}
        },
        overrides
      )

    %FeedCheckpoint{}
    |> FeedCheckpoint.changeset(attributes)
    |> Repo.insert!()
  end

  defp read_fixture, do: @fixture |> File.read!() |> Jason.decode!()
end
