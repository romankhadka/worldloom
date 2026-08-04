defmodule Worldloom.Loom.StoreTest do
  use Worldloom.DataCase, async: true

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store

  test "commits a source batch in sequence order with deterministic visuals" do
    events = [source_event(2), source_event(1)]

    assert {:ok, inserted} = Store.commit_external(events, checkpoint("cursor-2"))

    assert Enum.map(inserted, & &1.id) == Enum.sort(Enum.map(inserted, & &1.id))
    assert Enum.map(inserted, & &1.external_id) == ["revision-2", "revision-1"]

    assert Enum.all?(
             inserted,
             &match?(%{"spread" => _, "bend" => _, "pulse" => _}, &1.payload["visual"])
           )

    refute Enum.any?(inserted, &Map.has_key?(&1.payload, "request_nonce"))

    assert %FeedCheckpoint{cursor: "cursor-2"} = Repo.get(FeedCheckpoint, "wikimedia")
  end

  test "deduplicates upstream identities without error and still advances the checkpoint" do
    event = source_event(1)

    assert {:ok, [_inserted]} = Store.commit_external([event], checkpoint("cursor-1"))

    assert {:ok, []} =
             Store.commit_external(
               [event],
               checkpoint("cursor-2", %{last_successful_at: ~U[2026-08-03 12:01:00.000000Z]})
             )

    checkpoint = Repo.get!(FeedCheckpoint, "wikimedia")
    assert checkpoint.cursor == "cursor-2"
    assert checkpoint.last_successful_at == ~U[2026-08-03 12:01:00.000000Z]
  end

  test "an empty successful batch updates feed freshness" do
    assert {:ok, []} =
             Store.commit_external(
               [],
               checkpoint("cursor-empty", %{
                 source: "usgs",
                 last_successful_at: ~U[2026-08-03 13:00:00.123456Z]
               })
             )

    checkpoint = Repo.get!(FeedCheckpoint, "usgs")
    assert checkpoint.cursor == "cursor-empty"
    assert checkpoint.last_successful_at == ~U[2026-08-03 13:00:00.123456Z]
  end

  test "events and cursor or etag changes commit atomically" do
    assert {:ok, [event]} =
             Store.commit_external(
               [source_event(1)],
               checkpoint("cursor-1", %{etag: ~s("etag-1")})
             )

    checkpoint = Repo.get!(FeedCheckpoint, "wikimedia")
    assert checkpoint.cursor == "cursor-1"
    assert checkpoint.etag == ~s("etag-1")
    assert {:ok, ^event} = Store.fetch(event.id)
  end

  test "a rejected checkpoint rolls back otherwise valid event inserts" do
    invalid_checkpoint = checkpoint(String.duplicate("x", 8_193))

    assert {:error, %Ecto.Changeset{}} =
             Store.commit_external([source_event(1)], invalid_checkpoint)

    assert Store.latest() == []
    assert Repo.get(FeedCheckpoint, "wikimedia") == nil
  end

  test "an invalid event rolls back checkpoint movement" do
    assert {:ok, []} = Store.commit_external([], checkpoint("cursor-before"))
    invalid_event = %{source_event(1) | lane: 2.0}

    assert {:error, {:invalid_event, {:lane, :out_of_bounds}}} =
             Store.commit_external([invalid_event], checkpoint("cursor-after"))

    assert Repo.get!(FeedCheckpoint, "wikimedia").cursor == "cursor-before"
    assert Store.latest() == []
  end

  test "visitor commits never persist their nonce or create a feed checkpoint" do
    visitor =
      SourceEvent.new!(%{
        kind: :illuminate,
        source: :visitor,
        external_id: nil,
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        lane: 0.75,
        intensity: 0.8,
        payload: %{"summary" => "A visitor illuminated a thread"}
      })

    assert {:ok, event} = Store.commit_visitor(visitor, "secret-request-nonce")
    assert event.source == "visitor"
    assert event.external_id == nil
    assert event.payload["summary"] == "A visitor illuminated a thread"
    refute inspect(event.payload) =~ "secret-request-nonce"
    assert Repo.all(FeedCheckpoint) == []
  end

  test "latest history is ascending and cannot exceed six hundred rows" do
    events = Enum.map(1..605, &source_event/1)

    assert {:ok, inserted} = Store.commit_external(events, checkpoint("cursor-605"))
    latest = Store.latest(600)

    assert length(latest) == 600
    assert Enum.map(latest, & &1.id) == inserted |> Enum.drop(5) |> Enum.map(& &1.id)
    assert_raise ArgumentError, ~r/limit must be between 1 and 600/, fn -> Store.latest(601) end
  end

  test "around, after, before, ambient, fetch, and highest sequence are bounded and ordered" do
    weather = weather_event(0, ~U[2026-08-03 11:59:59.000000Z])
    wikimedia = Enum.map(1..6, &source_event/1)

    assert {:ok, [stored_weather]} =
             Store.commit_external([weather], checkpoint("weather-1", %{source: "open_meteo"}))

    assert {:ok, stored_wikimedia} =
             Store.commit_external(wikimedia, checkpoint("wiki-6"))

    all = [stored_weather | stored_wikimedia]
    target = Enum.at(all, 3)

    assert Enum.map(Store.around(target.id, 5), & &1.id) ==
             all |> Enum.slice(1, 5) |> Enum.map(& &1.id)

    assert Enum.map(Store.after(stored_weather.id, Enum.at(all, 4).id, 3), & &1.id) ==
             all |> Enum.slice(1, 3) |> Enum.map(& &1.id)

    assert Enum.map(Store.before(target.id, 2), & &1.id) ==
             all |> Enum.slice(1, 2) |> Enum.map(& &1.id)

    assert Store.ambient_before(List.last(all).id).id == stored_weather.id
    assert {:ok, ^target} = Store.fetch(target.id)
    assert :error = Store.fetch(List.last(all).id + 10_000)
    assert Store.highest_sequence() == List.last(all).id

    assert_raise ArgumentError, fn -> Store.after(target.id, target.id - 1, 10) end
    assert_raise ArgumentError, fn -> Store.before(target.id, 0) end
  end

  test "UTC chapters honor day seams and report counts and sequence bounds" do
    first_day_events = [
      source_event(1, ~U[2026-08-03 00:00:00.000000Z]),
      source_event(2, ~U[2026-08-03 23:59:59.999999Z])
    ]

    second_day_event = source_event(3, ~U[2026-08-04 00:00:00.000000Z])

    assert {:ok, first_day} =
             Store.commit_external(first_day_events, checkpoint("cursor-day-1"))

    assert {:ok, [second_day]} =
             Store.commit_external([second_day_event], checkpoint("cursor-day-2"))

    assert Enum.map(Store.chapter(~D[2026-08-03]), & &1.id) == Enum.map(first_day, & &1.id)
    assert Enum.map(Store.chapter(~D[2026-08-04]), & &1.id) == [second_day.id]

    assert [newest, oldest] = Store.chapters()

    assert newest == %{
             date: ~D[2026-08-04],
             count: 1,
             first_sequence: second_day.id,
             last_sequence: second_day.id
           }

    assert oldest == %{
             date: ~D[2026-08-03],
             count: 2,
             first_sequence: hd(first_day).id,
             last_sequence: List.last(first_day).id
           }
  end

  defp source_event(index, occurred_at \\ nil) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "revision-#{index}",
      occurred_at: occurred_at || DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second),
      lane: 0.4,
      intensity: 0.6,
      payload: %{"summary" => "Revision #{index} entered the weave"}
    })
  end

  defp weather_event(index, occurred_at) do
    SourceEvent.new!(%{
      kind: :weather,
      source: :open_meteo,
      external_id: "weather-#{index}",
      occurred_at: occurred_at,
      lane: 0.3,
      intensity: 0.5,
      payload: %{"summary" => "Weather crossed the fixed city anchors"}
    })
  end

  defp checkpoint(cursor, overrides \\ %{}) do
    Map.merge(
      %{
        source: "wikimedia",
        cursor: cursor,
        etag: nil,
        last_successful_at: ~U[2026-08-03 12:00:00.000000Z],
        metadata: %{}
      },
      overrides
    )
  end
end
