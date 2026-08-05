defmodule WorldloomWeb.WorldLiveTest do
  use WorldloomWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.SourceEvent
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.HealthMonitor

  test "serves every public mode with the stable loom skeleton", %{conn: conn} do
    [_event] = seed_events(1)

    {:ok, live_view, html} = live(conn, "/")

    assert html =~ "data-instruction-count=\"1\""

    for selector <- [
          "#worldloom",
          "#loom-canvas",
          "#live-edge",
          "#viewer-count",
          "#signal-legend",
          "#gesture-dock",
          "#timeline",
          "#archive-panel",
          "#about-panel",
          "#accessible-formations"
        ] do
      assert has_element?(live_view, selector)
    end

    assert {:ok, archive_view, _html} = live(conn, "/chapters")
    assert has_element?(archive_view, "#archive-panel[data-active]")

    assert {:ok, about_view, _html} = live(conn, "/about")
    assert has_element?(about_view, "#about-panel[data-active]")
  end

  test "stages the artwork without rendering empty detail chrome", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    assert has_element?(live_view, "#worldloom-introduction h1", "The world is weaving itself")
    assert has_element?(live_view, "#worldloom-introduction", "Public signals")
    assert has_element?(live_view, "#gesture-dock", "Touch the loom")
    refute has_element?(live_view, "#signal-detail")
  end

  test "caps initial history and every trusted detail window", %{conn: conn} do
    seed_events(605)

    {:ok, live_view, _html} = live(conn, "/")

    assert has_element?(live_view, "#loom-canvas[data-instruction-count='400']")
    assert has_element?(live_view, "#worldloom[data-event-window-size='400']")
  end

  test "validates chapter permalinks and keeps historical views read-only", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 12:00:00.000000Z])
    path = "/chapters/2026-08-03/#{event.id}"

    {:ok, chapter_view, _html} = live(conn, path)
    assert has_element?(chapter_view, "#gesture-dock[aria-disabled='true']")
    assert has_element?(chapter_view, "#return-live")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(chapter_view, "#gesture-#{gesture}[disabled]")
    end

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      Worldloom.Loom.Coordinator.topic(),
      {:loom_event, Instruction.from_event(event)}
    )

    refute_push_event chapter_view, "worldloom:event", _payload

    for invalid_path <- [
          "/chapters/not-a-date/#{event.id}",
          "/chapters/2026-08-04/#{event.id}",
          "/chapters/2026-08-03/not-a-sequence",
          "/chapters/2026-08-03/#{event.id + 100_000}"
        ] do
      assert_error_sent 404, fn -> get(recycle(conn), invalid_path) end
    end
  end

  test "derives live and chapter state from browser history patches", %{conn: conn} do
    [selected_event, _later_event] = seed_events(2, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    chapter_path = "/chapters/2026-08-03/#{selected_event.id}"
    render_hook(live_view, "select-formation", %{"sequence" => selected_event.id})

    assert_patch live_view, chapter_path
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")

    render_patch(live_view, "/")

    assert has_element?(live_view, "#worldloom[data-mode='live']")
    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='false']")

    for gesture <- ["tug", "knot", "illuminate"] do
      refute has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: root_url}
    assert URI.parse(root_url).path == "/"

    [broadcast_event] = seed_events(1, ~U[2026-08-03 16:00:00.000000Z])
    broadcast_instruction = Instruction.from_event(broadcast_event)

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      Worldloom.Loom.Coordinator.topic(),
      {:loom_event, broadcast_instruction}
    )

    assert_push_event live_view, "worldloom:event", ^broadcast_instruction

    render_patch(live_view, chapter_path)

    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")

    render_patch(live_view, "/")

    assert has_element?(live_view, "#worldloom[data-mode='live']")
    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#formation-#{broadcast_event.id}")
  end

  test "tracks only the aggregate connected viewer count", %{conn: conn} do
    {:ok, first_view, _html} = live(conn, "/")
    {:ok, second_view, _html} = live(recycle(conn), "/about")

    assert eventually(fn -> has_element?(first_view, "#viewer-count", "2") end)
    assert eventually(fn -> has_element?(second_view, "#viewer-count", "2") end)
  end

  test "pushes committed events and bounded catch-up watermarks", %{conn: conn} do
    [first] = seed_events(1)
    {:ok, live_view, _html} = live(conn, "/")
    [second] = seed_events(1, DateTime.add(first.occurred_at, 1, :second))
    second_instruction = Instruction.from_event(second)

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      Worldloom.Loom.Coordinator.topic(),
      {:loom_event, second_instruction}
    )

    assert_push_event live_view, "worldloom:event", ^second_instruction

    render_hook(live_view, "sequence-gap", %{
      "after" => first.id,
      "through" => second.id
    })

    assert_push_event live_view, "worldloom:catch-up", %{
      instructions: [^second_instruction],
      watermark: watermark
    }

    assert watermark == second.id

    render_hook(live_view, "sequence-gap", %{
      "after" => second.id,
      "through" => second.id + 2
    })

    assert_push_event live_view, "worldloom:catch-up", %{instructions: [], watermark: empty_mark}
    assert empty_mark == second.id + 2

    render_hook(live_view, "sequence-gap", %{
      "after" => second.id,
      "through" => second.id + 601
    })

    assert_push_event live_view, "worldloom:reload", %{
      instructions: reloaded,
      watermark: reload_watermark
    }

    assert length(reloaded) <= 400
    assert reload_watermark >= second.id
  end

  test "uses a server-owned cursor for throttled bounded history", %{conn: conn} do
    seed_events(5)
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "history-before", %{"sequence" => 999_999_999})

    assert_push_event live_view, "worldloom:history", %{
      instructions: [],
      archive_start?: true
    }

    render_hook(live_view, "history-before", %{"sequence" => 1})
    refute_push_event live_view, "worldloom:history", _throttled
  end

  test "receives shared safe feed health without polling in the view", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    safe_health = %{
      wikimedia: %{state: :live, observed_at: ~U[2026-08-03 12:00:00Z]},
      usgs: %{state: :quiet, observed_at: nil},
      open_meteo: %{state: :stale, observed_at: nil}
    }

    Phoenix.PubSub.broadcast(
      Worldloom.PubSub,
      HealthMonitor.topic(),
      {:feed_health, safe_health}
    )

    assert eventually(fn ->
             has_element?(live_view, "#signal-legend[data-usgs-state='quiet']") and
               has_element?(live_view, "#signal-legend[data-weather-state='stale']")
           end)
  end

  test "exposes direct gesture actions and adjusts the lane with keyboard events", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    for {gesture, label, description} <- [
          {"tug", "Tug", "Bend a strand"},
          {"knot", "Knot", "Join two paths"},
          {"illuminate", "Illuminate", "Awaken a junction"}
        ] do
      assert has_element?(
               live_view,
               "#gesture-#{gesture}[type='submit'][name='gesture'][value='#{gesture}'][aria-label='#{label}'][aria-describedby='gesture-#{gesture}-description']"
             )

      assert has_element?(live_view, "#gesture-#{gesture} .gesture-copy strong", label)

      assert has_element?(
               live_view,
               "#gesture-#{gesture}-description",
               description
             )
    end

    refute has_element?(live_view, "[aria-pressed]")
    refute has_element?(live_view, "#weave-gesture")

    render_hook(live_view, "lane-key", %{"key" => "ArrowUp"})
    assert has_element?(live_view, "#gesture-lane[value='0.55']")

    render_hook(live_view, "lane-key", %{"key" => "ArrowLeft"})
    assert has_element?(live_view, "#gesture-lane[value='0.5']")
  end

  test "gesture buttons commit directly at the current lane", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> form("#gesture-lane-form", %{"lane" => "0.7"})
    |> render_submit(%{"gesture" => "illuminate"})

    assert_push_event live_view, "worldloom:event", %{
      "kind" => "illuminate",
      "source" => "visitor",
      "lane" => 0.7
    }

    assert_push_event live_view, "worldloom:gesture-accepted", %{"sequence" => sequence}
    assert is_integer(sequence)

    assert has_element?(live_view, "#gesture-status", "Gesture joined the living edge")
    assert has_element?(live_view, "#gesture-status", "Gesture controls return in 30 seconds.")
    assert has_element?(live_view, "#gesture-cooldown-ring[data-seconds='30']")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    send(live_view.pid, :gesture_ready)

    assert eventually(fn ->
             has_element?(live_view, "#gesture-status", "Choose an action for the live edge") and
               not has_element?(live_view, "#gesture-cooldown-ring") and
               Enum.all?(["tug", "knot", "illuminate"], fn gesture ->
                 not has_element?(live_view, "#gesture-#{gesture}[disabled]")
               end)
           end)

    live_view
    |> form("#gesture-lane-form", %{"lane" => "0.5"})
    |> render_submit(%{"gesture" => "knot"})

    assert has_element?(live_view, "#gesture-status", "Try again in")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    send(live_view.pid, {:gesture_ready, make_ref()})

    assert eventually(fn ->
             Enum.all?(["tug", "knot", "illuminate"], fn gesture ->
               has_element?(live_view, "#gesture-#{gesture}[disabled]")
             end)
           end)
  end

  test "direct gesture boundary rejects malformed lane text", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> form("#gesture-lane-form")
    |> render_submit(%{"gesture" => "tug", "lane" => "sideways"})

    assert has_element?(live_view, "#gesture-status", "Choose a valid gesture and lane")
    refute_push_event live_view, "worldloom:event", _rejected
  end

  test "renders the Living Fiber semantics and public source attribution", %{conn: conn} do
    {:ok, live_view, html} = live(conn, "/")

    assert has_element?(live_view, "#wordmark", "Worldloom")
    assert has_element?(live_view, "#utc-chapter", "UTC")
    assert has_element?(live_view, "#viewer-count")
    assert has_element?(live_view, "#archive-link")
    assert has_element?(live_view, "#about-link")
    assert has_element?(live_view, "#share-worldloom")
    assert has_element?(live_view, "#share-status[aria-live='polite']")
    assert has_element?(live_view, "#mobile-worldloom-menu a[href='/chapters']", "Archive")
    assert has_element?(live_view, "#mobile-worldloom-menu a[href='/about']", "About")
    assert has_element?(live_view, "#mobile-worldloom-menu button", "Share")
    assert has_element?(live_view, "#signal-legend [data-family='wikimedia']")
    assert has_element?(live_view, "#signal-legend [data-family='usgs']")
    assert has_element?(live_view, "#signal-legend [data-family='open_meteo']")
    assert has_element?(live_view, "#signal-legend [data-family='visitor']")
    assert has_element?(live_view, "#signal-legend[data-usgs-state='quiet']")
    assert has_element?(live_view, "#signal-legend[data-weather-state='stale']")
    assert has_element?(live_view, "#live-summary[aria-live='polite']")

    assert html =~
             "Worldloom needs JavaScript to draw the living fabric. Its public source, privacy contract, and data-source documentation remain available in the repository."

    {:ok, about_view, _html} = live(recycle(conn), "/about")

    assert has_element?(
             about_view,
             ".about-lede",
             "Worldloom is one living public record. Activity from across the world enters as fiber, tension, atmosphere, and light—then remains part of the same shared fabric."
           )

    assert has_element?(about_view, ".about-sections section", "Public change, given form")

    assert has_element?(
             about_view,
             ".about-sections section",
             "Shape the present, never rewrite the past"
           )

    assert has_element?(about_view, ".about-sections section", "The weave survives the room")
    assert has_element?(about_view, ".about-sections section", "No identity enters the artwork")

    assert has_element?(
             about_view,
             ".about-sections section",
             "The canvas is not the only way in"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://stream.wikimedia.org/'][rel='noreferrer']",
             "Wikimedia"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://earthquake.usgs.gov/'][rel='noreferrer']",
             "USGS"
           )

    assert has_element?(
             about_view,
             "#source-attribution a[href='https://open-meteo.com/'][rel='noreferrer']",
             "Open-Meteo"
           )

    assert has_element?(about_view, "#source-attribution h2", "Public sources")

    assert has_element?(
             about_view,
             ".about-technology",
             "Worldloom is built with Phoenix LiveView, OTP, PubSub, Presence, PostgreSQL, and a deterministic Canvas 2D renderer."
           )

    assert has_element?(
             about_view,
             ".about-technology a[href='https://github.com/romankhadka/worldloom'][rel='noreferrer']",
             "Read the public source"
           )
  end

  test "renders a gesture only from its committed broadcast and exposes cooldown safely", %{
    conn: conn
  } do
    peer_id = System.unique_integer([:positive, :monotonic])

    peer_address =
      {127, rem(div(peer_id, 65_536), 256), rem(div(peer_id, 256), 256), rem(peer_id, 256)}

    conn =
      Plug.Test.put_peer_data(conn, %{address: peer_address, port: 40_000, ssl_cert: nil})

    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "gesture", %{"gesture" => "illuminate", "lane" => 0.72})

    assert_push_event live_view, "worldloom:event", %{
      "kind" => "illuminate",
      "source" => "visitor",
      "lane" => 0.72,
      "sequence" => sequence
    }

    assert {:ok, stored_event} = Store.fetch(sequence)
    assert stored_event.payload["summary"] == "A visitor illuminated a thread"
    assert Enum.sort(Map.keys(stored_event.payload)) == ["summary", "visual"]
    assert Enum.sort(Map.keys(stored_event.payload["visual"])) == ["bend", "pulse", "spread"]
    refute Map.has_key?(stored_event.payload, "visitor_identity")
    refute Map.has_key?(stored_event.payload, "peer_address")
    refute_push_event live_view, "worldloom:event", _duplicate

    render_hook(live_view, "gesture", %{"gesture" => "illuminate", "lane" => 0.72})
    assert has_element?(live_view, "#gesture-status", "Try again in 30 seconds")
    assert has_element?(live_view, "#gesture-status", "Gesture controls return in 30 seconds.")
    assert has_element?(live_view, "#gesture-cooldown-ring[data-seconds='30']")
    refute_push_event live_view, "worldloom:event", _rejected
  end

  test "rejects forged, panned-away, and historical gestures with safe text", %{conn: conn} do
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "gesture", %{"gesture" => "script", "lane" => "left"})
    assert has_element?(live_view, "#gesture-status", "Choose a valid gesture and lane")

    render_hook(live_view, "viewport-state", %{"at_live_edge" => false})
    assert has_element?(live_view, "#gesture-dock[aria-disabled='true']")
    assert has_element?(live_view, "#return-live")

    for gesture <- ["tug", "knot", "illuminate"] do
      assert has_element?(live_view, "#gesture-#{gesture}[disabled]")
    end

    render_hook(live_view, "gesture", %{"gesture" => "tug", "lane" => 0.5})
    assert has_element?(live_view, "#gesture-status", "Return to the live edge")

    [event] = seed_events(1, ~U[2026-08-03 14:00:00.000000Z])
    {:ok, chapter_view, _html} = live(recycle(conn), "/chapters/2026-08-03/#{event.id}")
    render_hook(chapter_view, "gesture", %{"gesture" => "tug", "lane" => 0.5})
    assert has_element?(chapter_view, "#gesture-status", "Return to the live edge")
  end

  test "resolves formation detail on the server and shares its generated permalink", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "select-formation", %{
      "sequence" => event.id,
      "summary" => "forged summary",
      "source" => "forged source"
    })

    path = "/chapters/2026-08-03/#{event.id}"
    assert_patch live_view, path
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
    refute render(live_view) =~ "forged summary"
    refute render(live_view) =~ event.external_id
    assert has_element?(live_view, "#share-link[readonly][value$='#{path}']")

    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: copied_url}
    assert String.ends_with?(copied_url, path)
  end

  test "dismisses trusted formation detail without changing its permalink", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 15:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    render_hook(live_view, "select-formation", %{"sequence" => event.id})

    path = "/chapters/2026-08-03/#{event.id}"
    assert_patch live_view, path
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    assert has_element?(live_view, "#signal-detail", "Public formation 1")

    live_view |> element("#signal-detail") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(live_view, "#signal-detail")
    assert has_element?(live_view, "#worldloom[data-mode='chapter']")
    live_view |> element("#share-worldloom") |> render_click()
    assert_push_event live_view, "worldloom:copy-link", %{url: copied_url}
    assert String.ends_with?(copied_url, path)
  end

  test "accessible formation controls open the same trusted detail", %{conn: conn} do
    [event] = seed_events(1, ~U[2026-08-03 16:00:00.000000Z])
    {:ok, live_view, _html} = live(conn, "/")

    live_view
    |> element("#formation-#{event.id}")
    |> render_click()

    assert_patch live_view, "/chapters/2026-08-03/#{event.id}"
    assert has_element?(live_view, "#signal-detail", "Public formation 1")
  end

  defp seed_events(count, start_time \\ ~U[2026-08-03 12:00:00.000000Z]) do
    unique = System.unique_integer([:positive, :monotonic])

    source_events =
      Enum.map(1..count, fn index ->
        SourceEvent.new!(%{
          kind: :wikimedia,
          source: :wikimedia,
          external_id: "world-live-#{unique}-#{index}",
          occurred_at: DateTime.add(start_time, index - 1, :second),
          lane: 0.4,
          intensity: 0.6,
          payload: %{"summary" => "Public formation #{index}"}
        })
      end)

    assert {:ok, events} =
             Store.commit_external(source_events, %{
               source: "wikimedia",
               cursor: "world-live-cursor-#{unique}",
               etag: nil,
               last_successful_at: start_time,
               metadata: %{}
             })

    events
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end
end
