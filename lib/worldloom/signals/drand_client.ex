defmodule Worldloom.Signals.DrandClient do
  @moduledoc false

  @derive {Inspect, only: []}
  @enforce_keys [
    :origins,
    :request,
    :connect_timeout,
    :pool_timeout,
    :receive_timeout,
    :task_timeout,
    :period,
    :genesis_time
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @body_limit 4_096
  @body_private :worldloom_drand_body
  @body_oversized_private :worldloom_drand_body_oversized
  @connect_timeout 5_000
  @genesis_time_max 253_402_300_799
  @info_keys ~w(beacon_id chain_hash genesis_seed genesis_time period public_key scheme)
  @json_safe_max 9_007_199_254_740_991
  @pool_timeout 5_000
  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @receive_timeout 5_000
  @relay_origins [
    "https://api.drand.sh",
    "https://api2.drand.sh",
    "https://api3.drand.sh"
  ]
  @round_keys ~w(round signature)
  @task_timeout 6_000
  @telemetry_event [:worldloom, :signals, :drand_client, :race]
  @user_agent "Worldloom/1.0 (+https://github.com/romankhadka/worldloom)"

  @spec new(keyword()) :: {:ok, t()} | {:error, :unavailable}
  def new(options) when is_list(options) do
    configuration = validate_configuration!(options)

    client =
      struct!(__MODULE__,
        origins: configuration.origins,
        request: configuration.request,
        connect_timeout: configuration.connect_timeout,
        pool_timeout: configuration.pool_timeout,
        receive_timeout: configuration.receive_timeout,
        task_timeout: configuration.task_timeout,
        period: nil,
        genesis_time: nil
      )

    case race(client, info_path(), &validate_chain_info/1) do
      {:ok, schedule} ->
        {:ok, %{client | period: schedule.period, genesis_time: schedule.genesis_time}}

      {:error, :unavailable} = unavailable ->
        unavailable
    end
  end

  def new(_options), do: invalid_configuration!()

  @spec schedule(t()) :: %{period: 3, genesis_time: pos_integer()}
  def schedule(%__MODULE__{period: 3, genesis_time: genesis_time})
      when is_integer(genesis_time) and genesis_time > 0 do
    %{period: 3, genesis_time: genesis_time}
  end

  @spec fetch_round(t(), pos_integer()) ::
          {:ok, %{round: pos_integer(), render_identity: String.t()}}
          | {:error, :unavailable}
  def fetch_round(%__MODULE__{} = client, requested_round)
      when is_integer(requested_round) and requested_round in 1..@json_safe_max do
    race(client, round_path(requested_round), &validate_round(&1, requested_round))
  end

  def fetch_round(%__MODULE__{}, _requested_round), do: {:error, :unavailable}

  defp validate_configuration!(options) do
    validated =
      Keyword.validate!(options,
        origins: @relay_origins,
        request: &default_request/2,
        connect_timeout: @connect_timeout,
        pool_timeout: @pool_timeout,
        receive_timeout: @receive_timeout,
        task_timeout: @task_timeout
      )

    configuration = Map.new(validated)

    if valid_origins?(configuration.origins) and is_function(configuration.request, 2) and
         positive_timeout?(configuration.connect_timeout) and
         positive_timeout?(configuration.pool_timeout) and
         positive_timeout?(configuration.receive_timeout) and
         positive_timeout?(configuration.task_timeout) do
      configuration
    else
      invalid_configuration!()
    end
  rescue
    _error in ArgumentError -> invalid_configuration!()
  end

  defp valid_origins?(origins) when is_list(origins) do
    length(origins) in 1..3 and length(Enum.uniq(origins)) == length(origins) and
      Enum.all?(origins, &(&1 in @relay_origins))
  end

  defp valid_origins?(_origins), do: false

  defp positive_timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp invalid_configuration! do
    raise ArgumentError, "invalid drand client configuration"
  end

  defp race(client, path, validator) do
    started_at = System.monotonic_time()

    race_result =
      client.origins
      |> Task.async_stream(
        fn origin -> request_and_validate(client, origin <> path, validator) end,
        ordered: false,
        max_concurrency: 3,
        timeout: client.task_timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:error, :unavailable}, fn
        {:ok, {:ok, accepted}}, _unavailable -> {:halt, {:ok, accepted}}
        _rejected, unavailable -> {:cont, unavailable}
      end)

    outcome = if match?({:ok, _accepted}, race_result), do: :ok, else: :unavailable

    :telemetry.execute(
      @telemetry_event,
      %{duration: System.monotonic_time() - started_at},
      %{outcome: outcome, relay_count: length(client.origins)}
    )

    race_result
  end

  defp request_and_validate(client, url, validator) do
    with {:ok, %Req.Response{} = response} <-
           safe_request(client.request, url, request_options(client)),
         true <- response.status == 200,
         true <- json_content_type?(response),
         {:ok, body} <- bounded_body(response),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, accepted} <- validator.(decoded) do
      {:ok, accepted}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  defp safe_request(request, url, options) do
    try do
      request.(url, options)
    rescue
      _error -> {:error, :unavailable}
    catch
      _kind, _reason -> {:error, :unavailable}
    end
  end

  defp request_options(client) do
    [
      headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
      connect_options: [timeout: client.connect_timeout],
      pool_timeout: client.pool_timeout,
      receive_timeout: client.receive_timeout,
      retry: false,
      redirect: false,
      compressed: false,
      raw: true,
      decode_body: false,
      into: &accumulate_body/2
    ]
  end

  defp default_request(url, options), do: Req.get(url, options)

  defp accumulate_body({:data, chunk}, {request, response}) when is_binary(chunk) do
    accumulated = Req.Response.get_private(response, @body_private, "")

    if byte_size(chunk) <= @body_limit - byte_size(accumulated) do
      response = Req.Response.put_private(response, @body_private, accumulated <> chunk)
      {:cont, {request, response}}
    else
      response = Req.Response.put_private(response, @body_oversized_private, true)
      {:halt, {request, response}}
    end
  end

  defp accumulate_body(_unknown_chunk, {request, response}) do
    response = Req.Response.put_private(response, @body_oversized_private, true)
    {:halt, {request, response}}
  end

  defp bounded_body(response) do
    if Req.Response.get_private(response, @body_oversized_private, false) do
      {:error, :unavailable}
    else
      case Req.Response.get_private(response, @body_private, :not_streamed) do
        body when is_binary(body) -> bounded_binary(body)
        :not_streamed -> bounded_binary(response.body)
      end
    end
  end

  defp bounded_binary(body) when is_binary(body) and byte_size(body) <= @body_limit,
    do: {:ok, body}

  defp bounded_binary(_body), do: {:error, :unavailable}

  defp json_content_type?(response) do
    case Req.Response.get_header(response, "content-type") do
      [content_type] ->
        content_type
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("application/json")

      _missing_or_ambiguous ->
        false
    end
  end

  defp validate_chain_info(chain_info) when is_map(chain_info) do
    with true <- exact_keys?(chain_info, @info_keys),
         "quicknet" <- chain_info["beacon_id"],
         @quicknet_chain_hash <- chain_info["chain_hash"],
         3 <- chain_info["period"],
         genesis_time when is_integer(genesis_time) and genesis_time in 1..@genesis_time_max <-
           chain_info["genesis_time"],
         true <- lowercase_hex?(chain_info["genesis_seed"], 64),
         true <- lowercase_hex?(chain_info["public_key"], 192),
         "bls-unchained-g1-rfc9380" <- chain_info["scheme"] do
      {:ok, %{period: 3, genesis_time: genesis_time}}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp validate_chain_info(_chain_info), do: {:error, :unavailable}

  defp validate_round(round_response, requested_round) when is_map(round_response) do
    with true <- exact_keys?(round_response, @round_keys),
         ^requested_round <- round_response["round"],
         true <- requested_round in 1..@json_safe_max,
         signature when is_binary(signature) <- round_response["signature"],
         true <- lowercase_hex?(signature, 96),
         {:ok, signature_bytes} <- Base.decode16(signature, case: :lower) do
      render_identity =
        signature_bytes
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, %{round: requested_round, render_identity: render_identity}}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp validate_round(_round_response, _requested_round), do: {:error, :unavailable}

  defp exact_keys?(payload, keys), do: payload |> Map.keys() |> Enum.sort() |> Kernel.==(keys)

  defp lowercase_hex?(encoded, length) when is_binary(encoded) and byte_size(encoded) == length,
    do: Regex.match?(~r/\A[0-9a-f]+\z/, encoded)

  defp lowercase_hex?(_encoded, _length), do: false

  defp info_path, do: "/v2/chains/#{@quicknet_chain_hash}/info"

  defp round_path(round),
    do: "/v2/chains/#{@quicknet_chain_hash}/rounds/#{round}"
end
