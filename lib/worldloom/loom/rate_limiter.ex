defmodule Worldloom.Loom.RateLimiter do
  use GenServer

  @identity_cooldown_ms 30_000
  @peer_capacity 10.0
  @peer_refill_per_ms 1.0 / 1_000
  @peer_expiry_ms 10_000
  @cleanup_interval_ms 60_000

  @type authorization :: :ok | {:error, :cooldown | :rate_limited, pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @spec authorize(GenServer.server(), String.t(), term(), integer()) :: authorization()
  def authorize(server \\ __MODULE__, identity, peer_address, now_ms)
      when is_binary(identity) and identity != "" and is_integer(now_ms) do
    GenServer.call(server, {:authorize, identity, peer_address, now_ms})
  end

  @impl true
  def init(options) do
    table = Keyword.get(options, :table, __MODULE__)

    :ets.new(table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    state = %{
      table: table,
      salt: Keyword.get(options, :salt, Application.fetch_env!(:worldloom, :rate_limit_salt)),
      clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end),
      timer: Keyword.get(options, :timer, &Process.send_after/3)
    }

    state.timer.(self(), :cleanup, @cleanup_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:authorize, identity, peer_address, now_ms}, _from, state) do
    identity_key = keyed_value(state.salt, {:identity, identity})
    peer_key = keyed_value(state.salt, peer_address)

    case identity_cooldown(state.table, identity_key, now_ms) do
      {:error, retry_after_seconds} ->
        {:reply, {:error, :cooldown, retry_after_seconds}, state}

      :ok ->
        authorize_peer(state, identity_key, peer_key, now_ms)
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now_ms = state.clock.()

    Enum.each(:ets.tab2list(state.table), fn
      {{:identity, key}, expires_at} when expires_at <= now_ms ->
        :ets.delete(state.table, {:identity, key})

      {{:peer, key}, _tokens, last_refill_at}
      when now_ms - last_refill_at >= @peer_expiry_ms ->
        :ets.delete(state.table, {:peer, key})

      _active_row ->
        :ok
    end)

    state.timer.(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  defp identity_cooldown(table, identity_key, now_ms) do
    case :ets.lookup(table, {:identity, identity_key}) do
      [{{:identity, ^identity_key}, expires_at}] when expires_at > now_ms ->
        {:error, retry_after_seconds(expires_at - now_ms)}

      _available ->
        :ok
    end
  end

  defp authorize_peer(state, identity_key, peer_key, now_ms) do
    {available_tokens, _last_refill_at} = peer_tokens(state.table, peer_key, now_ms)

    if available_tokens >= 1.0 do
      :ets.insert(
        state.table,
        {{:peer, peer_key}, available_tokens - 1.0, now_ms}
      )

      :ets.insert(
        state.table,
        {{:identity, identity_key}, now_ms + @identity_cooldown_ms}
      )

      {:reply, :ok, state}
    else
      milliseconds_until_token = ceil((1.0 - available_tokens) / @peer_refill_per_ms)
      {:reply, {:error, :rate_limited, retry_after_seconds(milliseconds_until_token)}, state}
    end
  end

  defp peer_tokens(table, peer_key, now_ms) do
    case :ets.lookup(table, {:peer, peer_key}) do
      [{{:peer, ^peer_key}, tokens, last_refill_at}] ->
        elapsed_ms = max(now_ms - last_refill_at, 0)
        {min(@peer_capacity, tokens + elapsed_ms * @peer_refill_per_ms), now_ms}

      [] ->
        {@peer_capacity, now_ms}
    end
  end

  defp keyed_value(salt, input) do
    :crypto.mac(:hmac, :sha256, salt, :erlang.term_to_binary(input))
    |> binary_part(0, 12)
  end

  defp retry_after_seconds(milliseconds), do: max(1, ceil(milliseconds / 1_000))
  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
