defmodule WorldloomWeb.E2EControllerTest do
  use ExUnit.Case, async: false

  if Application.compile_env(:worldloom, :e2e_routes, false) do
    use WorldloomWeb, :verified_routes

    import Plug.Conn
    import Phoenix.ConnTest

    alias Worldloom.Loom.Coordinator
    alias Worldloom.Loom.Event
    alias Worldloom.Repo
    alias Worldloom.Signals.HealthMonitor

    @endpoint WorldloomWeb.Endpoint

    test "loads an allowlisted durable scene without starting feed workers" do
      coordinator_start_count = Coordinator.start_count()

      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/__e2e__/scenes/balanced", Jason.encode!(%{snapshot: valid_snapshot()}))

      assert json_response(response, 200) == %{
               "commit_watermark" => 11,
               "scene" => "balanced",
               "window_end" => "2026-08-08T12:01:00Z"
             }

      snapshot = Coordinator.current_snapshot()
      assert snapshot.commit_watermark == 11
      assert DateTime.compare(snapshot.window_end, ~U[2026-08-08 12:01:00.000Z]) == :eq
      assert Coordinator.start_count() == coordinator_start_count + 1
      assert Supervisor.which_children(Worldloom.Signals.Supervisor) == []

      signal_config = Application.fetch_env!(:worldloom, Worldloom.Signals)
      refute signal_config.enabled
      refute signal_config.bluesky_enabled
      refute signal_config.ripe_enabled
      refute signal_config.solana_enabled
      refute signal_config.drand_enabled

      rendered_world =
        build_conn()
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()

      for family <- ~w(bluesky ripe_ris solana drand) do
        assert rendered_world
               |> LazyHTML.query("#legend-#{family}[data-health-state='live']")
               |> LazyHTML.attribute("id") == ["legend-#{family}"]
      end

      assert HealthMonitor.current()
             |> Map.values()
             |> Enum.all?(&(&1.state == :live))

      %{rows: [[sequence_value, true]]} =
        Repo.query!("SELECT last_value, is_called FROM loom_events_id_seq")

      assert sequence_value == 11
    end

    test "rejects unknown scenes and malformed snapshots without changing the loom" do
      before_snapshot = Coordinator.current_snapshot()
      before_events = durable_events()

      unknown_response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/__e2e__/scenes/not-a-scene",
          Jason.encode!(%{snapshot: valid_snapshot()})
        )

      assert json_response(unknown_response, 404) == %{"error" => "unknown scene"}

      invalid_response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/__e2e__/scenes/balanced", Jason.encode!(%{snapshot: %{}}))

      assert json_response(invalid_response, 422) == %{"error" => "invalid snapshot"}
      assert Coordinator.current_snapshot() == before_snapshot
      assert durable_events() == before_events
    end

    test "rejects projection drift before changing the durable scene" do
      established_response = post_scene("balanced", valid_snapshot())
      assert json_response(established_response, 200)["commit_watermark"] == 11
      established_snapshot = Coordinator.current_snapshot()
      established_events = durable_events()

      drifting_snapshot =
        update_in(
          valid_snapshot(),
          ["display_events", Access.at(0), "occurred_at"],
          fn _occurred_at -> "2026-08-08T11:58:00.000Z" end
        )

      drifting_response = post_scene("balanced", drifting_snapshot)

      assert json_response(drifting_response, 422) == %{"error" => "invalid snapshot"}
      assert Coordinator.current_snapshot() == established_snapshot
      assert durable_events() == established_events
    end

    test "accepts the maximum legal display memory and ambient envelope" do
      response = post_scene("balanced", maximum_snapshot())

      assert json_response(response, 200) == %{
               "commit_watermark" => 605,
               "scene" => "balanced",
               "window_end" => "2026-08-08T12:01:00Z"
             }

      snapshot = Coordinator.current_snapshot()
      assert length(snapshot.display_events) == 600
      assert length(snapshot.memory_events) == 4
      assert snapshot.ambient.id == 605
      assert Repo.aggregate(Event, :count) == 605
    end

    test "rejects each scene collection above its independent limit" do
      display_overflow =
        maximum_snapshot()
        |> Map.put("display_events", display_instructions(601))
        |> Map.put("memory_events", [])
        |> Map.put("ambient", nil)
        |> Map.put("commit_watermark", 601)

      memory_overflow =
        maximum_snapshot()
        |> Map.put("display_events", display_instructions(1))
        |> Map.put("memory_events", memory_instructions(5))
        |> Map.put("ambient", nil)
        |> Map.put("commit_watermark", 605)

      ambient_overflow = Map.put(maximum_snapshot(), "ambient", [ambient_instruction(605)])

      for invalid_snapshot <- [display_overflow, memory_overflow, ambient_overflow] do
        before_events = durable_events()
        response = post_scene("balanced", invalid_snapshot)

        assert json_response(response, 422) == %{"error" => "invalid snapshot"}
        assert durable_events() == before_events
      end
    end

    test "injects only the server-owned health profile for each scene" do
      delayed_response = post_scene("delayed-recovery", valid_snapshot())
      assert json_response(delayed_response, 200)["scene"] == "delayed-recovery"

      delayed_health = HealthMonitor.current()
      assert delayed_health.ripe_ris.state == :quiet

      assert delayed_health
             |> Map.delete(:ripe_ris)
             |> Map.values()
             |> Enum.all?(&(&1.state == :live))

      outage_response = post_scene("total-outage", valid_snapshot())
      assert json_response(outage_response, 200)["scene"] == "total-outage"

      assert HealthMonitor.current()
             |> Map.values()
             |> Enum.all?(&(&1 == %{state: :disconnected, observed_at: nil}))
    end

    defp valid_snapshot do
      %{
        "snapshot_version" => 1,
        "window_end" => "2026-08-08T12:01:00.000Z",
        "commit_watermark" => 11,
        "display_events" => [
          instruction(%{
            "sequence" => 10,
            "kind" => "wikimedia",
            "source" => "wikimedia",
            "occurred_at" => "2026-08-08T12:01:00.000Z"
          })
        ],
        "memory_events" => [],
        "ambient" =>
          instruction(%{
            "sequence" => 11,
            "kind" => "weather",
            "source" => "open_meteo",
            "occurred_at" => "2026-08-08T11:59:30.000Z"
          })
      }
    end

    defp maximum_snapshot do
      %{
        "snapshot_version" => 1,
        "window_end" => "2026-08-08T12:01:00.000Z",
        "commit_watermark" => 605,
        "display_events" => display_instructions(600),
        "memory_events" => memory_instructions(4),
        "ambient" => ambient_instruction(605)
      }
    end

    defp display_instructions(count) do
      Enum.map(1..count, fn sequence ->
        {kind, source} =
          case rem(sequence - 1, 3) do
            0 -> {"wikimedia", "wikimedia"}
            1 -> {"public_activity", "bluesky"}
            2 -> {"route_change", "ripe_ris"}
          end

        instruction(%{
          "sequence" => sequence,
          "kind" => kind,
          "source" => source,
          "occurred_at" => "2026-08-08T12:01:00.000Z"
        })
      end)
    end

    defp memory_instructions(count) do
      earthquake =
        instruction(%{
          "sequence" => 601,
          "kind" => "earthquake",
          "source" => "usgs",
          "occurred_at" => "2026-08-08T11:59:59.000Z"
        })

      visitors =
        1..max(count - 1, 0)
        |> Enum.map(fn offset ->
          instruction(%{
            "sequence" => 601 + offset,
            "kind" => "illuminate",
            "source" => "visitor",
            "occurred_at" =>
              DateTime.to_iso8601(DateTime.add(~U[2026-08-08 11:59:56.000Z], offset, :second))
          })
        end)
        |> Enum.reverse()

      [earthquake | visitors]
      |> Enum.take(count)
    end

    defp ambient_instruction(sequence) do
      instruction(%{
        "sequence" => sequence,
        "kind" => "weather",
        "source" => "open_meteo",
        "occurred_at" => "2026-08-08T11:59:30.000Z"
      })
    end

    defp instruction(overrides) do
      Map.merge(
        %{
          "sequence" => 1,
          "kind" => "wikimedia",
          "source" => "wikimedia",
          "occurred_at" => "2026-08-08T12:00:00.000Z",
          "render_version" => 1,
          "seed" => 17,
          "lane" => 0.2,
          "intensity" => 0.5,
          "visual" => %{"spread" => 0.4, "bend" => -0.1, "pulse" => 0.48},
          "summary" => "A deterministic signal moved through the weave"
        },
        overrides
      )
    end

    defp post_scene(name, snapshot) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/__e2e__/scenes/#{name}", Jason.encode!(%{snapshot: snapshot}))
    end

    defp durable_events do
      Event
      |> Repo.all()
      |> Enum.sort_by(& &1.id)
    end
  end
end
