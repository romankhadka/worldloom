defmodule Worldloom.Signals.FakeUpstreamTest do
  use ExUnit.Case, async: false

  alias Worldloom.Signals.SSEParser
  alias Worldloom.Signals.BlueskyWindow
  alias Worldloom.Signals.RipeWindow
  alias Worldloom.Signals.WebSocketTransport
  alias Worldloom.TestSupport.FakeUpstream

  @ca_file Path.expand("test/support/fixtures/tls/localhost_ca.pem")
  @clock_time ~U[2026-08-08 16:00:00Z]
  @drand_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"

  test "serves Wikimedia cursor replay and deterministic HTTP fixtures" do
    server = start_fake_upstream()
    urls = FakeUpstream.urls(server)

    assert FakeUpstream.ca_file() == @ca_file

    first_response = get!(urls.wikimedia <> "?once=true")
    {first_frames, ""} = SSEParser.push("", first_response.body)

    assert Enum.map(first_frames, & &1.id) == ["wikimedia-1", "wikimedia-2", "wikimedia-3"]

    replay_response =
      get!(urls.wikimedia <> "?once=true", headers: [{"last-event-id", "wikimedia-2"}])

    {replay_frames, ""} = SSEParser.push("", replay_response.body)

    assert Enum.map(replay_frames, & &1.id) == [
             "wikimedia-3",
             "wikimedia-4",
             "wikimedia-5"
           ]

    assert Enum.all?(replay_frames, fn frame ->
             {:ok, %{"meta" => %{"dt" => "2026-08-08T16:00:00Z"}}} =
               Jason.decode(frame.data)

             true
           end)

    usgs_response = get!(urls.usgs)
    assert usgs_response.status == 200
    assert usgs_response.body["type"] == "FeatureCollection"
    assert length(usgs_response.body["features"]) == 3
    assert usgs_response.body["metadata"]["generated"] == 1_786_204_800_000

    assert Enum.map(usgs_response.body["features"], &get_in(&1, ["properties", "time"])) ==
             [1_786_204_801_000, 1_786_204_802_000, 1_786_204_803_000]

    weather_response = get!(urls.open_meteo)
    assert weather_response.status == 200
    assert length(weather_response.body) == 12

    assert Enum.map(weather_response.body, &get_in(&1, ["current", "temperature_2m"])) ==
             [14.0, 28.0, 22.0, 14.0, 28.0, 22.0, 14.0, 28.0, 22.0, 14.0, 28.0, 22.0]

    assert Enum.map(weather_response.body, &get_in(&1, ["current", "time"])) ==
             List.duplicate("2026-08-08T16:00", 12)

    assert FakeUpstream.drand_chain_info_url(server) ==
             urls.drand_origin <> "/v2/chains/#{@drand_chain_hash}/info"

    assert FakeUpstream.drand_round_url(server, 42) ==
             urls.drand_origin <> "/v2/chains/#{@drand_chain_hash}/rounds/42"

    chain_info_response = get!(FakeUpstream.drand_chain_info_url(server))
    assert chain_info_response.body["chain_hash"] == @drand_chain_hash

    assert get!(urls.stats).body["drand"] == counter(0, 0, 0, 0, 1, 0)

    round_response = get!(FakeUpstream.drand_round_url(server, 42))

    assert round_response.body == %{
             "round" => 42,
             "signature" =>
               "95a9f9f5b231b7714de1553105d8ffdf3dcda24cfdb1e689319bccf79a9c8ce430a91b811fbfaf763900bc998b5d686a"
           }

    assert get!(urls.stats).body["drand"] == counter(0, 0, 0, 0, 2, 1)
  end

  test "records Bluesky and RIPE subscriptions and emits deterministic windows" do
    server = start_fake_upstream()
    urls = FakeUpstream.urls(server)

    bluesky_url =
      urls.bluesky <>
        "?wantedCollections=app.bsky.feed.post&wantedCollections=app.bsky.feed.repost" <>
        "&maxMessageSizeBytes=262144&compress=false"

    bluesky = connect_socket!(bluesky_url)
    {bluesky, bluesky_frames} = collect_json_frames(bluesky, 9)

    assert length(bluesky_frames) == 9
    assert hd(bluesky_frames)["time_us"] == DateTime.to_unix(@clock_time, :microsecond) + 100_000
    assert hd(bluesky_frames)["kind"] == "commit"

    {bluesky, second_bluesky_window} = collect_json_frames(bluesky, 9)

    assert hd(second_bluesky_window)["time_us"] ==
             DateTime.to_unix(@clock_time, :microsecond) + 100_000

    ripe = connect_socket!(urls.ripe_ris)
    ripe = send_json!(ripe, %{"type" => "request_rrc_list", "data" => nil})
    {ripe, [collector_list]} = collect_json_frames(ripe, 1)

    assert collector_list == %{
             "type" => "ris_rrc_list",
             "data" => ["rrc00.ripe.net", "rrc01.ripe.net"]
           }

    subscription = %{
      "type" => "ris_subscribe",
      "data" => %{
        "type" => "UPDATE",
        "host" => "rrc00.ripe.net",
        "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
      }
    }

    ripe = send_json!(ripe, subscription)
    {ripe, [acknowledgement]} = collect_json_frames(ripe, 1)

    assert acknowledgement == %{
             "type" => "ris_subscribe_ok",
             "data" => %{
               "subscription" => %{"type" => "UPDATE", "host" => "rrc00.ripe.net"},
               "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
             }
           }

    {_ripe, ripe_frames} = collect_json_frames(ripe, 4)

    assert length(ripe_frames) == 4
    assert get_in(hd(ripe_frames), ["data", "timestamp"]) == 1_786_204_800.1
    assert get_in(hd(ripe_frames), ["data", "host"]) == "rrc00.ripe.net"

    stats = get!(urls.stats).body
    assert stats["bluesky"]["connection_opens"] == 1
    assert stats["bluesky"]["active_connections"] == 1
    assert stats["bluesky"]["peak_connections"] == 1
    assert stats["bluesky"]["subscriptions"] == 1
    assert stats["bluesky"]["requests"] == 0
    assert stats["bluesky"]["emitted_windows"] >= 2
    assert stats["ripe_ris"] == counter(1, 1, 1, 1, 0, 1)

    WebSocketTransport.close(bluesky)
  end

  test "keeps sustained Bluesky and RIPE frames within provider future-skew bounds" do
    monotonic_origin = System.monotonic_time(:millisecond)

    ticking_clock = fn ->
      elapsed = System.monotonic_time(:millisecond) - monotonic_origin
      DateTime.add(@clock_time, elapsed, :millisecond)
    end

    server =
      start_supervised!({
        FakeUpstream,
        clock: ticking_clock, cadence_ms: 50
      })

    urls = FakeUpstream.urls(server)

    bluesky =
      connect_socket!(
        urls.bluesky <>
          "?wantedCollections=app.bsky.feed.post&wantedCollections=app.bsky.feed.repost" <>
          "&maxMessageSizeBytes=262144&compress=false"
      )

    {bluesky, bluesky_frames} = collect_json_frames(bluesky, 36)
    bluesky_received_at = ticking_clock.()
    bluesky_receipt = DateTime.to_unix(bluesky_received_at, :microsecond)
    bluesky_window = BlueskyWindow.new(bluesky_received_at)

    assert Enum.all?(bluesky_frames, fn
             %{"time_us" => time_us} when is_integer(time_us) ->
               time_us <= bluesky_receipt + 5_000_000

             _frame ->
               true
           end)

    refute Enum.any?(bluesky_frames, fn frame ->
             match?(
               {:drop, :timestamp_in_future, _window},
               BlueskyWindow.add(bluesky_window, frame, bluesky_received_at)
             )
           end)

    WebSocketTransport.close(bluesky)

    ripe = connect_socket!(urls.ripe_ris)
    ripe = send_json!(ripe, %{"type" => "request_rrc_list", "data" => nil})
    {ripe, [_collector_list]} = collect_json_frames(ripe, 1)

    ripe =
      Enum.reduce(["rrc00.ripe.net", "rrc01.ripe.net"], ripe, fn collector, transport ->
        transport =
          send_json!(transport, %{
            "type" => "ris_subscribe",
            "data" => %{
              "type" => "UPDATE",
              "host" => collector,
              "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
            }
          })

        {transport, [_acknowledgement]} = collect_json_frames(transport, 1)
        transport
      end)

    {ripe, ripe_frames} = collect_json_frames(ripe, 16)
    ripe_received_at = ticking_clock.()
    ripe_receipt = DateTime.to_unix(ripe_received_at, :microsecond)

    ripe_window =
      ripe_received_at
      |> RipeWindow.new(["rrc00", "rrc01"])
      |> RipeWindow.authorize(["rrc00.ripe.net", "rrc01.ripe.net"])

    assert Enum.all?(ripe_frames, fn frame ->
             case get_in(frame, ["data", "timestamp"]) do
               timestamp when is_number(timestamp) ->
                 round(timestamp * 1_000_000) <= ripe_receipt + 5_000_000

               _invalid ->
                 true
             end
           end)

    refute Enum.any?(ripe_frames, fn frame ->
             match?(
               {:drop, :timestamp_in_future, _window},
               RipeWindow.add(ripe_window, frame, ripe_received_at)
             )
           end)

    WebSocketTransport.close(ripe)
  end

  test "serves Solana slots only when the server explicitly enables them" do
    disabled_server = start_fake_upstream()
    assert FakeUpstream.urls(disabled_server).solana == nil

    enabled_server =
      start_supervised!({
        FakeUpstream,
        clock: fn -> @clock_time end, cadence_ms: 50, solana: true
      })

    urls = FakeUpstream.urls(enabled_server)
    solana = connect_socket!(urls.solana)
    solana = send_json!(solana, %{"jsonrpc" => "2.0", "id" => 1, "method" => "slotSubscribe"})
    {solana, [acknowledgement]} = collect_json_frames(solana, 1)

    assert acknowledgement == %{"jsonrpc" => "2.0", "id" => 1, "result" => 7}

    {_solana, frames} = collect_json_frames(solana, 5)

    assert Enum.map(frames, &get_in(&1, ["params", "result", "slot"])) == [
             101,
             102,
             105,
             105,
             104
           ]

    assert get!(urls.stats).body["solana"] == counter(1, 1, 1, 1, 0, 1)
  end

  test "tracks active and peak streaming connections without retaining clients" do
    server = start_fake_upstream()
    urls = FakeUpstream.urls(server)

    socket = connect_socket!(urls.bluesky)

    assert get!(urls.stats).body["bluesky"] == counter(1, 1, 1, 0, 0, 0)

    WebSocketTransport.close(socket)

    assert_eventually(fn ->
      get!(urls.stats).body["bluesky"] == counter(1, 0, 1, 0, 0, 0)
    end)
  end

  test "binds a requested loopback port for standalone load runs" do
    port = unused_port()

    server =
      start_supervised!({
        FakeUpstream,
        clock: fn -> @clock_time end, cadence_ms: 50, port: port
      })

    assert URI.parse(FakeUpstream.urls(server).stats).port == port
  end

  test "publishes fixed aggregate counters without retaining request or source content" do
    server = start_fake_upstream()
    urls = FakeUpstream.urls(server)

    get!(urls.usgs,
      headers: [
        {"cookie", "visitor-secret"},
        {"x-forwarded-for", "192.0.2.55"},
        {"x-source-content", "raw-frame-secret"}
      ]
    )

    get!(urls.wikimedia <> "?once=true", headers: [{"last-event-id", "cursor-secret"}])

    stats = get!(urls.stats).body

    assert Map.keys(stats) |> Enum.sort() ==
             ~w(bluesky drand open_meteo ripe_ris solana usgs wikimedia)

    Enum.each(stats, fn {_source, source_stats} ->
      assert Map.keys(source_stats) |> Enum.sort() ==
               ~w(active_connections connection_opens emitted_windows peak_connections requests subscriptions)

      assert Enum.all?(source_stats, fn {_counter, count} ->
               is_integer(count) and count >= 0
             end)
    end)

    encoded_stats = Jason.encode!(stats)

    for forbidden <- [
          "visitor-secret",
          "192.0.2.55",
          "cursor-secret",
          "raw-frame-secret",
          "cookie",
          "identity",
          "cursor",
          "raw",
          "content",
          "prefix",
          "peer",
          "account"
        ] do
      refute encoded_stats =~ forbidden
    end
  end

  defp start_fake_upstream do
    start_supervised!({
      FakeUpstream,
      clock: fn -> @clock_time end, cadence_ms: 50
    })
  end

  defp get!(url, options \\ []) do
    options =
      Keyword.merge(options,
        connect_options: [
          protocols: [:http1],
          transport_opts: [cacertfile: @ca_file]
        ]
      )

    Req.get!(url, options)
  end

  defp connect_socket!(url) do
    assert {:ok, transport} = WebSocketTransport.connect(url, cacertfile: @ca_file)
    await_connected(transport)
  end

  defp await_connected(transport) do
    receive do
      message ->
        case WebSocketTransport.stream(transport, message) do
          {:ok, connected, events} ->
            if :connected in events, do: connected, else: await_connected(connected)

          :unknown ->
            await_connected(transport)

          {:error, reason, _failed} ->
            flunk("WebSocket failed before connecting: #{inspect(reason)}")
        end
    after
      1_000 -> flunk("expected a WebSocket connection")
    end
  end

  defp send_json!(transport, message) do
    assert {:ok, updated} =
             WebSocketTransport.send_frame(transport, {:text, Jason.encode!(message)})

    updated
  end

  defp collect_json_frames(transport, count, collected \\ []) do
    if length(collected) >= count do
      {transport, Enum.take(collected, count)}
    else
      receive do
        message ->
          case WebSocketTransport.stream(transport, message) do
            {:ok, updated, events} ->
              decoded =
                for {:text, encoded} <- events do
                  Jason.decode!(encoded)
                end

              collect_json_frames(updated, count, collected ++ decoded)

            :unknown ->
              collect_json_frames(transport, count, collected)

            {:error, reason, _failed} ->
              flunk("WebSocket failed while collecting frames: #{inspect(reason)}")
          end
      after
        1_000 -> flunk("expected #{count} WebSocket frames, received #{length(collected)}")
      end
    end
  end

  defp counter(
         connection_opens,
         active_connections,
         peak_connections,
         subscriptions,
         requests,
         emitted_windows
       ) do
    %{
      "connection_opens" => connection_opens,
      "active_connections" => active_connections,
      "peak_connections" => peak_connections,
      "subscriptions" => subscriptions,
      "requests" => requests,
      "emitted_windows" => emitted_windows
    }
  end

  defp assert_eventually(assertion, attempts \\ 50)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("expected condition to become true")

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
