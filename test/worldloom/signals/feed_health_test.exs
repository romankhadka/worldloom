defmodule Worldloom.Signals.FeedHealthTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.FeedHealth

  @now ~U[2026-08-03 12:30:00.000000Z]

  test "projects exact live boundaries without leaking checkpoint details" do
    checkpoints = [
      checkpoint("wikimedia", DateTime.add(@now, -10, :minute), %{
        "last_event_at" => @now |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      }),
      checkpoint("usgs", DateTime.add(@now, -3, :minute), %{}, ~s("private-etag")),
      checkpoint("open_meteo", DateTime.add(@now, -30, :minute))
    ]

    assert FeedHealth.project(checkpoints, @now) == %{
             wikimedia: %{
               state: :live,
               observed_at: DateTime.add(@now, -60, :second)
             },
             usgs: %{state: :live, observed_at: DateTime.add(@now, -3, :minute)},
             open_meteo: %{state: :live, observed_at: DateTime.add(@now, -30, :minute)}
           }
  end

  test "projects values beyond each threshold as quiet or stale" do
    checkpoints = [
      checkpoint("wikimedia", @now, %{
        "last_event_at" => @now |> DateTime.add(-61, :second) |> DateTime.to_iso8601()
      }),
      checkpoint("usgs", DateTime.add(@now, -181, :second)),
      checkpoint("open_meteo", DateTime.add(@now, -1_801, :second))
    ]

    projection = FeedHealth.project(checkpoints, @now)

    assert projection.wikimedia.state == :quiet
    assert projection.usgs.state == :quiet
    assert projection.open_meteo.state == :stale
  end

  test "missing or malformed checkpoints use safe empty states" do
    checkpoints = [checkpoint("wikimedia", @now, %{"last_event_at" => "not-a-time"})]

    assert FeedHealth.project(checkpoints, @now) == %{
             wikimedia: %{state: :quiet, observed_at: nil},
             usgs: %{state: :quiet, observed_at: nil},
             open_meteo: %{state: :stale, observed_at: nil}
           }
  end

  defp checkpoint(source, successful_at, metadata \\ %{}, etag \\ nil) do
    %{
      source: source,
      cursor: "private-cursor",
      etag: etag,
      last_successful_at: successful_at,
      metadata: metadata
    }
  end
end
