defmodule Worldloom.Signals.DrandClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Worldloom.Signals.DrandClient

  @fixtures "test/support/fixtures/feeds"
  @json_safe_max 9_007_199_254_740_991
  @maximum_unix_second 253_402_300_799
  @origins ["https://api.drand.sh", "https://api2.drand.sh", "https://api3.drand.sh"]
  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @info_path "/v2/chains/#{@quicknet_chain_hash}/info"
  @round_path "/v2/chains/#{@quicknet_chain_hash}/rounds/42"
  @render_identity "8ada64bae5c6c0f5540a6a13af56e663240edfbd2c76ac6a8f27671eb7259ce3"
  @telemetry_event [:worldloom, :signals, :drand_client, :race]

  test "races exact chain-info and round paths until the first valid response" do
    owner = self()
    chain_info_body = fixture_body("drand_chain_info.json")
    round_body = fixture_round_body(42)

    request = fn url, options ->
      send(owner, {:request, url, options})

      cond do
        String.ends_with?(url, @info_path) and String.starts_with?(url, Enum.at(@origins, 0)) ->
          json_response(%{"beacon_id" => "quicknet"})

        String.ends_with?(url, @info_path) and String.starts_with?(url, Enum.at(@origins, 1)) ->
          Process.sleep(10)
          response(chain_info_body)

        String.ends_with?(url, @round_path) and String.starts_with?(url, Enum.at(@origins, 0)) ->
          json_response(%{"round" => 41, "signature" => String.duplicate("a", 96)})

        String.ends_with?(url, @round_path) and String.starts_with?(url, Enum.at(@origins, 1)) ->
          Process.sleep(10)
          response(round_body)

        true ->
          response("unavailable", status: 503, content_type: "text/plain")
      end
    end

    assert {:ok, client} = DrandClient.new(request: request)
    assert DrandClient.schedule(client) == %{period: 3, genesis_time: 1_692_803_367}

    assert DrandClient.fetch_round(client, 42) ==
             {:ok, %{round: 42, render_identity: @render_identity}}

    requested_urls = collect_request_urls(6)

    assert Enum.any?(requested_urls, &(&1 == Enum.at(@origins, 0) <> @info_path))
    assert Enum.any?(requested_urls, &(&1 == Enum.at(@origins, 1) <> @info_path))
    assert Enum.any?(requested_urls, &(&1 == Enum.at(@origins, 0) <> @round_path))
    assert Enum.any?(requested_urls, &(&1 == Enum.at(@origins, 1) <> @round_path))
    refute Enum.any?(requested_urls, &String.ends_with?(&1, "/rounds/latest"))

    inspected = inspect(client)

    for secret <- [
          Enum.at(@origins, 0),
          @quicknet_chain_hash,
          "quicknet",
          "1692803367",
          @render_identity,
          fixture_signature(42)
        ] do
      refute inspected =~ secret
    end
  end

  test "pins one to three unique production relay origins and rejects unsafe configuration" do
    chain_info_body = fixture_body("drand_chain_info.json")
    request = fn _url, _options -> response(chain_info_body) end

    for origins <- [Enum.take(@origins, 1), Enum.take(@origins, 2), @origins] do
      assert {:ok, client} = DrandClient.new(origins: origins, request: request)
      assert DrandClient.schedule(client) == %{period: 3, genesis_time: 1_692_803_367}
    end

    invalid_configurations = [
      [origins: []],
      [origins: Enum.at(@origins, 0)],
      [origins: [Enum.at(@origins, 0), Enum.at(@origins, 0)]],
      [origins: @origins ++ [Enum.at(@origins, 0)]],
      [origins: ["http://api.drand.sh"]],
      [origins: ["https://api.drand.sh/"]],
      [origins: ["https://example.com"]],
      [request: :req],
      [connect_timeout: 0],
      [pool_timeout: 12],
      [send_timeout: -1],
      [receive_timeout: :infinity],
      [task_timeout: 1.5],
      [unknown: true]
    ]

    for configuration <- invalid_configurations do
      assert_raise ArgumentError, ~r/invalid drand client configuration/, fn ->
        DrandClient.new(Keyword.put_new(configuration, :request, request))
      end
    end
  end

  test "sets bounded request options and caps streamed bytes before manual decoding" do
    owner = self()
    chain_info_body = fixture_body("drand_chain_info.json")
    round_body = fixture_round_body(42)

    request = fn url, options ->
      send(owner, {:options, url, options})
      body = if String.ends_with?(url, @info_path), do: chain_info_body, else: round_body
      streamed_response(options, [body])
    end

    assert {:ok, client} =
             DrandClient.new(
               origins: [Enum.at(@origins, 0)],
               request: request,
               connect_timeout: 11,
               send_timeout: 12,
               receive_timeout: 13
             )

    assert {:ok, %{round: 42}} = DrandClient.fetch_round(client, 42)

    for expected_url <- [Enum.at(@origins, 0) <> @info_path, Enum.at(@origins, 0) <> @round_path] do
      assert_receive {:options, ^expected_url, options}

      assert Keyword.fetch!(options, :connect_options) == [
               timeout: 11,
               transport_opts: [send_timeout: 12]
             ]

      assert Keyword.fetch!(options, :receive_timeout) == 13
      assert Keyword.fetch!(options, :retry) == false
      assert Keyword.fetch!(options, :redirect) == false
      assert Keyword.fetch!(options, :compressed) == false
      assert Keyword.fetch!(options, :raw) == true
      assert Keyword.fetch!(options, :decode_body) == false
      assert is_function(Keyword.fetch!(options, :into), 2)
      assert {"accept", "application/json"} in Keyword.fetch!(options, :headers)
    end

    overflow_request = fn url, options ->
      if String.ends_with?(url, @info_path) do
        streamed_response(options, [chain_info_body])
      else
        streamed_response(options, [String.duplicate(" ", 4_096), "{"])
      end
    end

    assert {:ok, overflow_client} =
             DrandClient.new(origins: [Enum.at(@origins, 0)], request: overflow_request)

    assert {:error, :unavailable} = DrandClient.fetch_round(overflow_client, 42)
  end

  test "rejects oversized injected bodies without trusting content length" do
    chain_info_body = fixture_body("drand_chain_info.json")

    request = fn url, _options ->
      if String.ends_with?(url, @info_path) do
        response(chain_info_body)
      else
        response(String.duplicate("x", 4_097), headers: [{"content-length", "1"}])
      end
    end

    assert {:ok, client} =
             DrandClient.new(origins: [Enum.at(@origins, 0)], request: request)

    assert {:error, :unavailable} = DrandClient.fetch_round(client, 42)
  end

  test "accepts only the exact current Quicknet chain-info contract" do
    valid = fixture_json("drand_chain_info.json")

    invalid_bodies = [
      Map.put(valid, "beacon_id", "default"),
      Map.put(valid, "chain_hash", String.duplicate("0", 64)),
      Map.put(valid, "period", 4),
      Map.put(valid, "genesis_time", 0),
      Map.put(valid, "genesis_time", @maximum_unix_second + 1),
      Map.put(valid, "genesis_seed", String.upcase(valid["genesis_seed"])),
      Map.put(valid, "genesis_seed", String.duplicate("a", 63)),
      Map.put(valid, "public_key", String.upcase(valid["public_key"])),
      Map.put(valid, "public_key", String.duplicate("a", 191)),
      Map.put(valid, "scheme", "pedersen-bls-unchained"),
      Map.put(valid, "unexpected", true)
    ]

    for invalid <- invalid_bodies do
      request = fn _url, _options -> json_response(invalid) end

      assert {:error, :unavailable} =
               DrandClient.new(origins: [Enum.at(@origins, 0)], request: request)
    end

    for unavailable_response <- [
          response("{"),
          response(fixture_body("drand_chain_info.json"), status: 503),
          response(fixture_body("drand_chain_info.json"), content_type: "text/plain"),
          response(String.duplicate("x", 4_097))
        ] do
      request = fn _url, _options -> unavailable_response end

      assert {:error, :unavailable} =
               DrandClient.new(origins: [Enum.at(@origins, 0)], request: request)
    end
  end

  test "accepts only an exact matching JSON-safe round and lowercase signature" do
    chain_info_body = fixture_body("drand_chain_info.json")
    valid = fixture_round(42)

    invalid_bodies = [
      Map.put(valid, "round", 41),
      Map.put(valid, "round", 0),
      Map.put(valid, "round", @json_safe_max + 1),
      Map.put(valid, "signature", String.upcase(valid["signature"])),
      Map.put(valid, "signature", String.duplicate("a", 95)),
      Map.put(valid, "signature", String.duplicate("g", 96)),
      Map.put(valid, "randomness", String.duplicate("a", 64)),
      Map.put(valid, "previous_signature", String.duplicate("a", 96)),
      Map.put(valid, "unexpected", true)
    ]

    for invalid <- invalid_bodies do
      request = response_router(chain_info_body, Jason.encode!(invalid))
      assert {:ok, client} = DrandClient.new(origins: [Enum.at(@origins, 0)], request: request)
      assert {:error, :unavailable} = DrandClient.fetch_round(client, 42)
    end

    for unavailable_round <- [
          response("{"),
          response(fixture_round_body(42), status: 302),
          response(fixture_round_body(42), content_type: "application/octet-stream"),
          response(String.duplicate("x", 4_097))
        ] do
      request = fn url, _options ->
        if String.ends_with?(url, @info_path),
          do: response(chain_info_body),
          else: unavailable_round
      end

      assert {:ok, client} = DrandClient.new(origins: [Enum.at(@origins, 0)], request: request)
      assert {:error, :unavailable} = DrandClient.fetch_round(client, 42)
    end
  end

  test "bounds concurrency and terminates every losing task when the race halts" do
    owner = self()
    chain_info_body = fixture_body("drand_chain_info.json")

    request = fn url, _options ->
      send(owner, {:started, self(), url})

      receive do
        {:respond, body} -> response(body)
      after
        1_000 ->
          send(owner, {:delayed, self()})
          response(chain_info_body)
      end
    end

    caller = Task.async(fn -> DrandClient.new(request: request, task_timeout: 500) end)

    started =
      for _index <- 1..3 do
        assert_receive {:started, pid, url}, 200
        {pid, url}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 3

    assert started |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             Enum.map(@origins, &(&1 <> @info_path))

    refute_receive {:started, _pid, _url}, 30

    monitors = Enum.map(started, fn {pid, _url} -> {pid, Process.monitor(pid)} end)
    {winner, _url} = hd(started)
    send(winner, {:respond, chain_info_body})

    assert {:ok, client} = Task.await(caller, 1_000)
    assert DrandClient.schedule(client) == %{period: 3, genesis_time: 1_692_803_367}

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 200
    end

    refute_receive {:delayed, _pid}, 100
  end

  test "collapses timeouts, transport failures, raises, and exits without caller failure or leakage" do
    owner = self()
    secret = "signature=never-log-this"
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, test_process ->
          send(test_process, {:telemetry, event, measurements, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = fn url, _options ->
      cond do
        String.starts_with?(url, Enum.at(@origins, 0)) -> raise secret
        String.starts_with?(url, Enum.at(@origins, 1)) -> exit(secret)
        true -> Process.sleep(:infinity)
      end
    end

    log =
      capture_log(fn ->
        assert {:error, :unavailable} = DrandClient.new(request: request, task_timeout: 20)
      end)

    refute log =~ secret
    refute log =~ Enum.at(@origins, 0)

    assert_receive {:telemetry, @telemetry_event, measurements, metadata}
    assert Map.keys(measurements) == [:duration]
    assert Map.keys(metadata) |> Enum.sort() == [:outcome, :relay_count]
    assert metadata == %{outcome: :unavailable, relay_count: 3}
    assert is_integer(measurements.duration) and measurements.duration >= 0
    refute inspect({measurements, metadata}) =~ secret
  end

  defp collect_request_urls(remaining, urls \\ [])
  defp collect_request_urls(0, urls), do: urls

  defp collect_request_urls(remaining, urls) do
    receive do
      {:request, url, _options} -> collect_request_urls(remaining - 1, [url | urls])
    after
      30 -> urls
    end
  end

  defp response_router(chain_info_body, round_body) do
    fn url, _options ->
      if String.ends_with?(url, @info_path),
        do: response(chain_info_body),
        else: response(round_body)
    end
  end

  defp streamed_response(options, chunks) do
    into = Keyword.fetch!(options, :into)
    request = Req.new()

    initial_response =
      Req.Response.new(status: 200, headers: [{"content-type", "application/json"}])

    {_request, response} =
      Enum.reduce_while(chunks, {request, initial_response}, fn chunk, accumulator ->
        case into.({:data, chunk}, accumulator) do
          {:cont, next_accumulator} -> {:cont, next_accumulator}
          {:halt, next_accumulator} -> {:halt, next_accumulator}
        end
      end)

    {:ok, response}
  end

  defp json_response(payload), do: response(Jason.encode!(payload))

  defp response(body, options \\ []) do
    content_type = Keyword.get(options, :content_type, "application/json; charset=utf-8")
    headers = [{"content-type", content_type} | Keyword.get(options, :headers, [])]

    {:ok,
     Req.Response.new(
       status: Keyword.get(options, :status, 200),
       headers: headers,
       body: body
     )}
  end

  defp fixture_round(round) do
    @fixtures
    |> Path.join("drand_rounds.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.find(&(Map.fetch!(&1, "round") == round))
  end

  defp fixture_round_body(round), do: round |> fixture_round() |> Jason.encode!()
  defp fixture_signature(round), do: round |> fixture_round() |> Map.fetch!("signature")

  defp fixture_json(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_body(name), do: name |> fixture_json() |> Jason.encode!()
end
