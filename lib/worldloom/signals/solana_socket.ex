defmodule Worldloom.Signals.SolanaSocket do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias Worldloom.Signals.SafeEndpoint
  alias Worldloom.Signals.SolanaSocket.State
  alias Worldloom.Signals.SolanaSlotAdapter
  alias Worldloom.Signals.WebSocketTransport

  @source :solana
  @source_name "solana"
  @flush_interval 1_000
  @upgrade_timeout 5_000
  @maximum_mailbox_depth 100
  @maximum_heap_words 2_000_000
  @json_safe_max 9_007_199_254_740_991

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, registration_options(name))
  end

  @impl true
  def init(options) do
    Process.flag(:max_heap_size, %{
      size: @maximum_heap_words,
      kill: true,
      error_logger: false
    })

    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    now = clock.()
    previous_slot = initial_slot(options)
    url = Keyword.fetch!(options, :url)
    {:ok, _uri} = SafeEndpoint.parse(url)

    state = %State{
      url: url,
      transport: nil,
      transport_module: Keyword.get(options, :transport, WebSocketTransport),
      transport_options: Keyword.get(options, :transport_options, []),
      window: SolanaSlotAdapter.new(now, previous_slot),
      subscription_id: nil,
      committed_slot: previous_slot,
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: clock,
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3),
      upgrade_generation: nil,
      reconnect_token: nil,
      subscribed?: false,
      attempt: 0
    }

    state.timer.(self(), :flush_window, @flush_interval)
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(message, state) do
    if mailbox_overloaded?() do
      overloaded =
        state
        |> close_transport()
        |> record_health({:drop, :mailbox})
        |> record_health(:disconnected)

      {:stop, :normal, overloaded}
    else
      dispatch(message, state)
    end
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _state} -> {:state, :redacted}
      {:message, _message} -> {:message, :redacted}
      {:reason, _reason} -> {:reason, :redacted}
      {:log, _log} -> {:log, :redacted}
      key_value -> key_value
    end)
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    close_transport(state)
    :ok
  end

  defp dispatch(:connect, %State{reconnect_token: nil} = state), do: connect(state)

  defp dispatch({:connect, token}, %State{reconnect_token: token} = state),
    do: connect(%{state | reconnect_token: nil})

  defp dispatch({:connect, _stale_token}, state), do: {:noreply, state}

  defp dispatch(
         {:upgrade_timeout, generation},
         %State{upgrade_generation: generation} = state
       ),
       do: {:noreply, disconnect(state, :timeout)}

  defp dispatch({:upgrade_timeout, _stale_generation}, state), do: {:noreply, state}

  defp dispatch(:flush_window, state) do
    now = state.clock.()
    updated = close_elapsed_window(state, now)
    updated.timer.(self(), :flush_window, @flush_interval)
    {:noreply, updated}
  end

  defp dispatch(_message, %State{transport: nil} = state), do: {:noreply, state}

  defp dispatch(message, state) do
    case state.transport_module.stream(state.transport, message) do
      {:ok, transport, events} when is_list(events) ->
        connected_state = %{state | transport: transport}

        if length(events) > @maximum_mailbox_depth do
          {:noreply, disconnect(connected_state, :backpressure)}
        else
          {:noreply, reduce_transport_events(events, connected_state)}
        end

      {:error, reason, transport} ->
        {:noreply, disconnect(%{state | transport: transport}, transport_drop(reason))}

      :unknown ->
        {:noreply, state}
    end
  end

  defp connect(state) do
    closed_state = close_transport(state)

    case state.transport_module.connect(state.url, state.transport_options) do
      {:ok, transport} ->
        generation = make_ref()
        state.timer.(self(), {:upgrade_timeout, generation}, @upgrade_timeout)

        {:noreply,
         %{
           closed_state
           | transport: transport,
             upgrade_generation: generation,
             reconnect_token: nil,
             subscribed?: false,
             subscription_id: nil
         }}

      {:error, reason} ->
        {:noreply, disconnect(closed_state, transport_drop(reason))}
    end
  end

  defp reduce_transport_events([], state), do: state

  defp reduce_transport_events([event | remaining], state) do
    case reduce_transport_event(event, state) do
      {:continue, %State{transport: nil} = updated} -> updated
      {:continue, updated} -> reduce_transport_events(remaining, updated)
      {:disconnect, updated} -> updated
    end
  end

  defp reduce_transport_event(:connected, state) do
    connected =
      state
      |> record_health(:connected)
      |> Map.put(:upgrade_generation, nil)

    case send_json(connected, SolanaSlotAdapter.subscription_message()) do
      {:ok, updated} -> {:continue, updated}
      {:error, failed} -> {:disconnect, disconnect(failed, :transport)}
    end
  end

  defp reduce_transport_event({:ping, payload}, state) do
    case state.transport_module.send_frame(state.transport, {:pong, payload}) do
      {:ok, transport} ->
        {:continue, %{state | transport: transport}}

      {:error, _reason, transport} ->
        {:disconnect, disconnect(%{state | transport: transport}, :transport)}
    end
  end

  defp reduce_transport_event({:pong, _payload}, state), do: {:continue, state}

  defp reduce_transport_event({:close, code, _reason}, state) do
    {:ok, transport} = state.transport_module.acknowledge_close(state.transport, code)
    {:disconnect, disconnect(%{state | transport: transport}, nil)}
  end

  defp reduce_transport_event({:binary, _payload}, state),
    do: {:disconnect, disconnect(state, :binary)}

  defp reduce_transport_event({:text, encoded_frame}, state) do
    receipt_at = state.clock.()
    {:continue, reduce_text_frame(encoded_frame, receipt_at, state)}
  end

  defp reduce_transport_event(_unsupported_frame, state),
    do: {:continue, record_health(state, {:drop, :unsupported})}

  defp reduce_text_frame(encoded_frame, receipt_at, state) do
    case Jason.decode(encoded_frame) do
      {:ok, frame} when is_map(frame) ->
        contacted = record_health(state, :contact)
        reduce_provider_frame(frame, receipt_at, contacted)

      _invalid ->
        record_health(state, {:drop, :malformed})
    end
  end

  defp reduce_provider_frame(frame, _receipt_at, %State{subscribed?: false} = state) do
    case acknowledgement(frame) do
      {:ok, subscription_id} ->
        %{state | subscribed?: true, subscription_id: subscription_id, attempt: 0}

      {:error, :invalid_acknowledgement} ->
        disconnect(state, :subscription)
    end
  end

  defp reduce_provider_frame(frame, receipt_at, state) do
    if matching_subscription?(frame, state.subscription_id) do
      add_to_window(frame, receipt_at, state)
    else
      disconnect(state, :subscription)
    end
  end

  defp add_to_window(frame, receipt_at, state) do
    case SolanaSlotAdapter.add(state.window, frame, receipt_at) do
      {:ok, window} ->
        %{state | window: window}

      {:close_required, window} ->
        close_and_retry(frame, receipt_at, %{state | window: window})

      {:drop, reason, window} ->
        state
        |> Map.put(:window, window)
        |> record_health({:drop, provider_drop(reason)})
    end
  end

  defp close_and_retry(frame, receipt_at, state) do
    case SolanaSlotAdapter.close(state.window, receipt_at) do
      {:flush, payload, next_window} ->
        case persist_window(state, payload, receipt_at) do
          {:ok, persisted} -> add_to_window(frame, receipt_at, %{persisted | window: next_window})
          {:error, failed} -> disconnect(failed, :persistence)
        end

      {:open, window} ->
        state
        |> Map.put(:window, window)
        |> record_health({:drop, :stale})
    end
  end

  defp close_elapsed_window(state, now) do
    case SolanaSlotAdapter.close(state.window, now) do
      {:open, window} ->
        %{state | window: window}

      {:flush, payload, next_window} ->
        case persist_window(state, payload, now) do
          {:ok, persisted} -> %{persisted | window: next_window}
          {:error, failed} -> disconnect(failed, :persistence)
        end
    end
  end

  defp persist_window(state, payload, successful_at) do
    checkpoint_slot = checkpoint_slot(payload, state.committed_slot)

    with {:ok, events} <- normalize_payload(payload),
         checkpoint = checkpoint(checkpoint_slot, successful_at),
         :ok <- state.buffer.(events, checkpoint) do
      updated =
        state
        |> Map.put(:committed_slot, checkpoint_slot)
        |> maybe_record_activity(events)

      {:ok, updated}
    else
      _failure -> {:error, state}
    end
  end

  defp normalize_payload(:empty), do: {:ok, []}

  defp normalize_payload(payload) do
    case Normalizer.solana_window(payload) do
      {:ok, event} -> {:ok, [event]}
      {:error, _reason} -> {:error, :invalid_window}
    end
  end

  defp checkpoint_slot(:empty, committed_slot), do: committed_slot
  defp checkpoint_slot(%{last_slot: last_slot}, _committed_slot), do: last_slot

  defp checkpoint(slot, successful_at) do
    %{
      source: @source_name,
      cursor: encoded_slot(slot),
      etag: nil,
      last_successful_at: successful_at,
      metadata: %{}
    }
  end

  defp maybe_record_activity(state, []), do: state
  defp maybe_record_activity(state, [_event]), do: record_health(state, {:activity, 1})

  defp acknowledgement(%{"jsonrpc" => "2.0", "id" => 1, "result" => subscription_id} = frame)
       when map_size(frame) == 3 and is_integer(subscription_id) and subscription_id >= 0,
       do: {:ok, subscription_id}

  defp acknowledgement(_frame), do: {:error, :invalid_acknowledgement}

  defp matching_subscription?(
         %{
           "jsonrpc" => "2.0",
           "method" => "slotNotification",
           "params" => %{"subscription" => subscription_id}
         },
         subscription_id
       ),
       do: true

  defp matching_subscription?(_frame, _subscription_id), do: false

  defp send_json(state, message) do
    case state.transport_module.send_frame(state.transport, {:text, Jason.encode!(message)}) do
      {:ok, transport} -> {:ok, %{state | transport: transport}}
      {:error, _reason, transport} -> {:error, %{state | transport: transport}}
    end
  end

  defp initial_slot(options) do
    checkpoint_cursor =
      if Keyword.has_key?(options, :previous_slot) do
        Keyword.get(options, :previous_slot)
      else
        case Repo.get(FeedCheckpoint, @source_name) do
          nil -> nil
          checkpoint -> checkpoint.cursor
        end
      end

    parse_slot(checkpoint_cursor)
  end

  defp parse_slot(nil), do: nil
  defp parse_slot(slot) when is_integer(slot) and slot in 0..@json_safe_max, do: slot

  defp parse_slot(slot) when is_binary(slot) do
    case Integer.parse(slot) do
      {parsed, ""} when parsed in 0..@json_safe_max -> parsed
      _invalid -> nil
    end
  end

  defp parse_slot(_slot), do: nil
  defp encoded_slot(nil), do: nil
  defp encoded_slot(slot), do: Integer.to_string(slot)

  defp disconnect(state, drop_reason) do
    disconnected = close_transport(state)

    disconnected =
      if drop_reason, do: record_health(disconnected, {:drop, drop_reason}), else: disconnected

    disconnected |> record_health(:disconnected) |> schedule_reconnect()
  end

  defp close_transport(%State{transport: nil} = state), do: state

  defp close_transport(state) do
    state.transport_module.close(state.transport)

    %{
      state
      | transport: nil,
        upgrade_generation: nil,
        subscribed?: false,
        subscription_id: nil
    }
  end

  defp schedule_reconnect(%State{reconnect_token: token} = state) when is_reference(token),
    do: state

  defp schedule_reconnect(state) do
    delay = Backoff.delay(state.attempt, state.random.())
    token = make_ref()
    state.timer.(self(), {:connect, token}, delay)

    state
    |> record_health({:retry, 1})
    |> Map.put(:attempt, state.attempt + 1)
    |> Map.put(:reconnect_token, token)
  end

  defp record_health(state, observation) do
    :ok = HealthRegistry.record(state.health_registry, @source, observation)
    state
  end

  defp provider_drop(:duplicate_slot), do: :duplicate

  defp provider_drop(reason) when reason in [:backward_slot, :late_event, :window_ahead],
    do: :stale

  defp provider_drop(_reason), do: :malformed

  defp transport_drop(:oversized), do: :oversized
  defp transport_drop(:frame_limit), do: :backpressure
  defp transport_drop(:timeout), do: :timeout
  defp transport_drop(_reason), do: :transport

  defp mailbox_overloaded? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, depth} -> depth > @maximum_mailbox_depth
      nil -> false
    end
  end

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
