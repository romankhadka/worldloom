defmodule Worldloom.Signals.FeedHealthTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.FeedHealth

  @now ~U[2026-08-03 12:30:00.000000Z]

  test "projects exact high-cadence and polling freshness boundaries" do
    inputs = %{
      observations: %{
        wikimedia: observation(:connected, 20),
        bluesky: observation(:connected, 20),
        ripe_ris: observation(:connected, 20),
        solana: observation(:connected, 20),
        drand: observation(:disconnected, 12),
        usgs: observation(:connected, 3 * 60),
        open_meteo: observation(:connected, 30 * 60)
      },
      checkpoints: [
        checkpoint("usgs", DateTime.add(@now, -3, :minute), ~s("private-etag")),
        checkpoint("open_meteo", DateTime.add(@now, -30, :minute))
      ]
    }

    assert FeedHealth.project(inputs, @now) == %{
             wikimedia: %{state: :live, observed_at: DateTime.add(@now, -20, :second)},
             bluesky: %{state: :live, observed_at: DateTime.add(@now, -20, :second)},
             ripe_ris: %{state: :live, observed_at: DateTime.add(@now, -20, :second)},
             solana: %{state: :live, observed_at: DateTime.add(@now, -20, :second)},
             drand: %{state: :live, observed_at: DateTime.add(@now, -12, :second)},
             usgs: %{state: :live, observed_at: DateTime.add(@now, -3, :minute)},
             open_meteo: %{state: :live, observed_at: DateTime.add(@now, -30, :minute)}
           }
  end

  test "projects disconnects immediately and ages quiet or stale activity honestly" do
    inputs = %{
      observations: %{
        wikimedia: observation(:connected, 21),
        bluesky: observation(:disconnected, 0),
        ripe_ris: observation(:connected, nil),
        solana: observation(:connected, 21),
        drand: observation(:connected, 13),
        usgs: observation(:disconnected, 181),
        open_meteo: observation(:disconnected, 1_801)
      },
      checkpoints: [
        checkpoint("usgs", DateTime.add(@now, -181, :second)),
        checkpoint("open_meteo", DateTime.add(@now, -1_801, :second))
      ]
    }

    projection = FeedHealth.project(inputs, @now)

    assert projection.wikimedia.state == :quiet
    assert projection.bluesky == %{state: :disconnected, observed_at: @now}
    assert projection.ripe_ris == %{state: :quiet, observed_at: nil}
    assert projection.solana.state == :quiet
    assert projection.drand.state == :stale
    assert projection.usgs.state == :quiet
    assert projection.open_meteo.state == :stale
  end

  test "polling freshness follows runtime contact while ignoring private checkpoint state" do
    inputs = %{
      observations: %{
        usgs: observation(:connected, 0),
        open_meteo: observation(:connected, 1_801)
      },
      checkpoints: [
        checkpoint("usgs", DateTime.add(@now, -10, :minute), "private-stale-etag"),
        checkpoint("open_meteo", @now, "private-fresh-etag")
      ]
    }

    projection = FeedHealth.project(inputs, @now)

    assert projection.usgs == %{state: :live, observed_at: @now}

    assert projection.open_meteo == %{
             state: :stale,
             observed_at: DateTime.add(@now, -1_801, :second)
           }

    refute inspect(projection) =~ "private-stale-etag"
    refute inspect(projection) =~ "private-fresh-etag"
  end

  test "missing or malformed inputs use fixed safe states without exposing private fields" do
    private_fields = %{
      cursor: "private-cursor",
      last_reason: "private-provider-reason",
      response_body: "private-response-body"
    }

    projection =
      FeedHealth.project(
        %{
          observations: %{
            wikimedia: Map.merge(observation(:connected, nil), private_fields),
            bluesky: %{connection: "private-connection", last_activity_at: "not-a-time"}
          },
          checkpoints: [
            %{
              source: "usgs",
              cursor: "private-cursor",
              etag: "private-etag",
              last_successful_at: "not-a-time",
              metadata: %{"response_body" => "private-response-body"}
            }
          ]
        },
        @now
      )

    assert projection == %{
             wikimedia: %{state: :quiet, observed_at: nil},
             bluesky: %{state: :disconnected, observed_at: nil},
             ripe_ris: %{state: :disconnected, observed_at: nil},
             solana: %{state: :disconnected, observed_at: nil},
             drand: %{state: :stale, observed_at: nil},
             usgs: %{state: :quiet, observed_at: nil},
             open_meteo: %{state: :stale, observed_at: nil}
           }

    inspected = inspect(projection)
    refute inspected =~ "private-cursor"
    refute inspected =~ "private-etag"
    refute inspected =~ "private-provider-reason"
    refute inspected =~ "private-response-body"
  end

  defp observation(connection, age_seconds) do
    observed_at = if is_integer(age_seconds), do: DateTime.add(@now, -age_seconds, :second)

    %{
      connection: connection,
      last_contact_at: observed_at,
      last_activity_at: observed_at
    }
  end

  defp checkpoint(source, successful_at, etag \\ nil) do
    %{
      source: source,
      cursor: "private-cursor",
      etag: etag,
      last_successful_at: successful_at,
      metadata: %{}
    }
  end
end
