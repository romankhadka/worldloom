defmodule Worldloom.Signals.WikimediaBucketTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.WikimediaBucket

  @fixture "test/support/fixtures/feeds/wikimedia_frames.json"
  @uint32_max 4_294_967_295

  test "aggregates the UTC window from second zero through second three" do
    [first, second, third] = read_frames()
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:03.999999Z])

    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("cursor-1", first))

    assert {:ok, bucket} =
             WikimediaBucket.add(
               bucket,
               frame("", put_in(second, ["meta", "dt"], "2026-08-03T12:00:02.500000Z"))
             )

    assert {:ok, bucket} =
             WikimediaBucket.add(
               bucket,
               frame(
                 "cursor-3",
                 put_in(third, ["meta", "dt"], "2026-08-03T12:00:03.999999Z")
               )
             )

    assert WikimediaBucket.flush(bucket) == %{
             window_start: ~U[2026-08-03 12:00:00Z],
             cursor: "cursor-3",
             count: 3,
             total_absolute_byte_delta: 45,
             languages: %{"de" => 1, "en" => 2},
             edit_types: %{"edit" => 2, "new" => 1}
           }
  end

  test "retains a crossed window for one second of late arrivals" do
    [first, second, third] = read_frames()

    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00Z])
    assert {:ok, bucket} = WikimediaBucket.add(bucket, frame("cursor-1", first))

    next_frame = put_in(second, ["meta", "dt"], "2026-08-03T12:00:04.000000Z")

    assert {:future, crossed_bucket, next_bucket} =
             WikimediaBucket.add(bucket, frame("cursor-2", next_frame))

    late_frame = put_in(third, ["meta", "dt"], "2026-08-03T12:00:03.999999Z")

    assert {:ok, completed_bucket} =
             WikimediaBucket.add(crossed_bucket, frame("late", late_frame))

    assert %{count: 2, cursor: "late"} = WikimediaBucket.flush(completed_bucket)

    assert %{window_start: ~U[2026-08-03 12:00:04Z], count: 1, cursor: "cursor-2"} =
             WikimediaBucket.flush(next_bucket)

    refute WikimediaBucket.elapsed?(completed_bucket, ~U[2026-08-03 12:00:04.999999Z])
    assert WikimediaBucket.elapsed?(completed_bucket, ~U[2026-08-03 12:00:05.000000Z])

    too_old = put_in(first, ["meta", "dt"], "2026-08-03T11:59:59.999999Z")

    assert {:drop, :late_event, ^completed_bucket} =
             WikimediaBucket.add(completed_bucket, frame("too-old", too_old))
  end

  test "uses exact modulo-four UTC boundaries before and after the Unix epoch" do
    assert WikimediaBucket.new(~U[2026-08-03 12:00:07.999999Z]).window_start ==
             ~U[2026-08-03 12:00:04Z]

    assert WikimediaBucket.new(~U[1969-12-31 23:59:59.999999Z]).window_start ==
             ~U[1969-12-31 23:59:56Z]

    assert WikimediaBucket.new(~U[1970-01-01 00:00:00.000000Z]).window_start ==
             ~U[1970-01-01 00:00:00Z]
  end

  test "saturates every aggregate counter at unsigned 32-bit maximum" do
    [first | _rest] = read_frames()

    bucket = %{
      WikimediaBucket.new(~U[2026-08-03 12:00:00Z])
      | count: @uint32_max,
        total_absolute_byte_delta: @uint32_max,
        languages: %{"en" => @uint32_max},
        edit_types: %{"edit" => @uint32_max}
    }

    assert {:ok, saturated} = WikimediaBucket.add(bucket, frame("cursor-max", first))
    assert saturated.count == @uint32_max
    assert saturated.total_absolute_byte_delta == @uint32_max
    assert saturated.languages["en"] == @uint32_max
    assert saturated.edit_types["edit"] == @uint32_max
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

    late_frame = put_in(first, ["meta", "dt"], "2026-08-03T11:59:56Z")

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

  test "an untouched elapsed window is empty" do
    bucket = WikimediaBucket.new(~U[2026-08-03 12:00:00Z])

    assert WikimediaBucket.elapsed?(bucket, ~U[2026-08-03 12:00:05Z])
    assert WikimediaBucket.flush(bucket) == :empty
  end

  defp read_frames do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp frame(id, payload), do: %{id: id, event: "recentchange", data: Jason.encode!(payload)}
end
