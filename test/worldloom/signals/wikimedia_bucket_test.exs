defmodule Worldloom.Signals.WikimediaBucketTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.WikimediaBucket

  @fixture "test/support/fixtures/feeds/wikimedia_frames.json"

  test "aggregates byte deltas, languages, edit types, and the latest cursor" do
    [first, second, third] = read_frames()
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00.999999Z])

    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("cursor-1", first))
    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("", second))
    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("cursor-3", third))

    assert WikimediaBucket.flush(bucket) == %{
             second: ~U[2026-08-03 12:00:00Z],
             cursor: "cursor-3",
             count: 3,
             total_absolute_byte_delta: 45,
             languages: %{"de" => 1, "en" => 2},
             edit_types: %{"edit" => 2, "new" => 1}
           }
  end

  test "crossing a second returns the completed and next buckets" do
    [first | _rest] = read_frames()
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00Z])
    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("cursor-1", first))

    next_frame = put_in(first, ["meta", "dt"], "2026-08-03T12:00:01Z")

    assert {:flush, completed, next_bucket} =
             WikimediaBucket.add(bucket, frame("cursor-2", next_frame))

    assert %{count: 1, cursor: "cursor-1"} = WikimediaBucket.flush(completed)

    assert %{
             second: ~U[2026-08-03 12:00:01Z],
             count: 1,
             cursor: "cursor-2"
           } = WikimediaBucket.flush(next_bucket)
  end

  test "heartbeat contact advances a non-empty cursor without creating an event" do
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00Z])

    assert {:heartbeat, heartbeat_bucket} =
             WikimediaBucket.add(bucket, %{id: "heartbeat-1", event: nil, data: ""})

    assert heartbeat_bucket.cursor == "heartbeat-1"
    assert WikimediaBucket.flush(heartbeat_bucket) == :empty
  end

  test "drops empty, malformed, late, and invalid frames without retaining raw fields" do
    [first | _rest] = read_frames()
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00Z])

    assert {:drop, :malformed_json, ^bucket} =
             WikimediaBucket.add(bucket, %{id: "bad", event: nil, data: "{"})

    assert {:drop, :invalid_event, ^bucket} =
             WikimediaBucket.add(bucket, %{id: "empty", event: nil, data: "{}"})

    late_frame = put_in(first, ["meta", "dt"], "2026-08-03T11:59:59Z")

    assert {:drop, :late_event, ^bucket} =
             WikimediaBucket.add(bucket, frame("late", late_frame))

    private_noise =
      first
      |> Map.put("user", "must disappear")
      |> Map.put("title", "must disappear")
      |> Map.put("comment", "must disappear")

    assert {:ok, sanitized_bucket} =
             WikimediaBucket.add(bucket, frame("cursor-safe", private_noise))

    refute inspect(sanitized_bucket) =~ "must disappear"
  end

  test "flush reports an untouched bucket as empty" do
    assert :empty =
             ~U[2026-08-03 12:00:00Z]
             |> WikimediaBucket.new()
             |> WikimediaBucket.flush()
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp frame(id, payload), do: %{id: id, event: "recentchange", data: Jason.encode!(payload)}
end
