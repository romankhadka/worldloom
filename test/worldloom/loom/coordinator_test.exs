defmodule Worldloom.Loom.CoordinatorTest do
  use Worldloom.DataCase

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store

  test "serializes concurrent commits and broadcasts them in sequence order" do
    {coordinator, topic} = start_coordinator()

    results =
      1..10
      |> Task.async_stream(
        fn index ->
          Coordinator.commit_external(
            coordinator,
            [source_event(index)],
            checkpoint("cursor-#{index}")
          )
        end,
        ordered: false,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, {:ok, [event]}} -> event end)

    instructions = receive_instructions(topic, 10)
    sequences = Enum.map(instructions, & &1["sequence"])

    assert sequences == Enum.sort(sequences)
    assert Enum.sort(sequences) == results |> Enum.map(& &1.id) |> Enum.sort()
    assert Coordinator.highest_sequence(coordinator) == List.last(sequences)
  end

  test "a separate sandbox process sees the row before the PubSub message is received" do
    {coordinator, topic} = start_coordinator()

    assert {:ok, [event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1)],
               checkpoint("cursor-1")
             )

    visible_event = Task.async(fn -> Store.fetch(event.id) end) |> Task.await()

    assert visible_event == {:ok, event}
    assert_receive {:loom_event, %{"sequence" => sequence}}, 500
    assert sequence == event.id
    assert topic != Coordinator.topic()
  end

  test "a rolled back commit produces no broadcast" do
    {coordinator, _topic} = start_coordinator()
    invalid_event = %{source_event(1) | intensity: 2.0}

    assert {:error, {:invalid_event, {:intensity, :out_of_bounds}}} =
             Coordinator.commit_external(
               coordinator,
               [invalid_event],
               checkpoint("cursor-invalid")
             )

    refute_receive {:loom_event, _instruction}, 100
    assert Coordinator.highest_sequence(coordinator) == 0
  end

  test "a duplicate source event is silent" do
    {coordinator, _topic} = start_coordinator()
    event = source_event(1)

    assert {:ok, [_inserted]} =
             Coordinator.commit_external(coordinator, [event], checkpoint("cursor-1"))

    assert_receive {:loom_event, _instruction}, 500

    assert {:ok, []} =
             Coordinator.commit_external(coordinator, [event], checkpoint("cursor-2"))

    refute_receive {:loom_event, _instruction}, 100
  end

  test "visitor events persist and broadcast their public instruction" do
    {coordinator, _topic} = start_coordinator()

    visitor =
      SourceEvent.new!(%{
        kind: :knot,
        source: :visitor,
        external_id: nil,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.5,
        intensity: 0.6,
        payload: %{"summary" => "A visitor tied a knot in the weave"}
      })

    assert {:ok, event} =
             Coordinator.commit_visitor(coordinator, visitor, "request-nonce-knot")

    assert {:ok, ^event} = Store.fetch(event.id)

    assert_receive {:loom_event,
                    %{
                      "sequence" => sequence,
                      "kind" => "knot",
                      "source" => "visitor"
                    }},
                   500

    assert sequence == event.id
  end

  test "highest sequence recovers from durable storage after restart" do
    topic = unique_topic()
    Phoenix.PubSub.subscribe(Worldloom.PubSub, topic)
    {:ok, coordinator} = Coordinator.start_link(name: nil, topic: topic)

    assert {:ok, [event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1)],
               checkpoint("cursor-1")
             )

    assert Coordinator.highest_sequence(coordinator) == event.id
    GenServer.stop(coordinator)

    {:ok, restarted} = Coordinator.start_link(name: nil, topic: topic)
    on_exit(fn -> Process.exit(restarted, :shutdown) end)

    assert Coordinator.highest_sequence(restarted) == event.id
  end

  test "emits privacy-safe commit telemetry" do
    {coordinator, _topic} = start_coordinator()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:worldloom, :loom, :commit],
        fn event_name, measurements, metadata, test_process ->
          send(test_process, {:telemetry, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, [_event]} =
             Coordinator.commit_external(
               coordinator,
               [source_event(1)],
               checkpoint("cursor-1")
             )

    assert_receive {:telemetry, [:worldloom, :loom, :commit], measurements,
                    %{kind: :external, status: :ok}},
                   500

    assert measurements.count == 1
    assert measurements.duration >= 0
    assert is_integer(measurements.highest_sequence)
  end

  defp start_coordinator do
    topic = unique_topic()
    Phoenix.PubSub.subscribe(Worldloom.PubSub, topic)
    {:ok, coordinator} = Coordinator.start_link(name: nil, topic: topic)
    on_exit(fn -> Process.exit(coordinator, :shutdown) end)
    {coordinator, topic}
  end

  defp unique_topic, do: "loom:test:#{System.unique_integer([:positive, :monotonic])}"

  defp receive_instructions(topic, count) do
    assert is_binary(topic)

    Enum.map(1..count, fn _index ->
      assert_receive {:loom_event, instruction}, 1_000
      instruction
    end)
  end

  defp source_event(index) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "coordinator-revision-#{index}",
      occurred_at: DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload: %{"summary" => "Coordinator revision #{index} entered the weave"}
    })
  end

  defp checkpoint(cursor) do
    %{
      source: "wikimedia",
      cursor: cursor,
      etag: nil,
      last_successful_at: ~U[2026-08-03 12:01:00.000000Z],
      metadata: %{}
    }
  end
end
