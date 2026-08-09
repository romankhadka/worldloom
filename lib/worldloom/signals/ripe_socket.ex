defmodule Worldloom.Signals.RipeSocket do
  use GenServer

  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias Worldloom.Signals.RipeWindow
  alias Worldloom.Signals.RipeSocket.State
  alias Worldloom.Signals.SafeEndpoint
  alias Worldloom.Signals.WebSocketTransport

  @source :ripe_ris
  @source_name "ripe_ris"
  @flush_interval 1_000
  @upgrade_timeout 5_000
  @subscription_timeout 5_000
  @maximum_mailbox_depth 100
  @maximum_heap_words 2_000_000

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
    collectors = Keyword.fetch!(options, :collectors)
    now = clock.()
    url = Keyword.fetch!(options, :url)
    {:ok, _uri} = SafeEndpoint.parse(url)

    state = %State{
      url: url,
      collectors: collectors,
      transport: nil,
      transport_module: Keyword.get(options, :transport, WebSocketTransport),
      transport_options: Keyword.get(options, :transport_options, []),
      window: RipeWindow.new(now, collectors),
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: clock,
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3),
      observation_listener:
        validate_observation_listener!(Keyword.get(options, :observation_listener)),
      upgrade_generation: nil,
      subscription_generation: nil,
      reconnect_token: nil,
      pending_acknowledgements: MapSet.new(),
      awaiting_acknowledgements?: false,
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

  defp dispatch(
         {:subscription_timeout, generation},
         %State{subscription_generation: generation} = state
       ),
       do: {:noreply, disconnect(state, :subscription)}

  defp dispatch({:subscription_timeout, _stale_generation}, state), do: {:noreply, state}

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
             subscription_generation: nil,
             reconnect_token: nil,
             pending_acknowledgements: MapSet.new(),
             awaiting_acknowledgements?: false,
             subscribed?: false
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
    subscription_generation = make_ref()
    state.timer.(self(), {:subscription_timeout, subscription_generation}, @subscription_timeout)

    connected =
      state
      |> record_health(:connected)
      |> Map.put(:upgrade_generation, nil)
      |> Map.put(:subscription_generation, subscription_generation)

    case send_json(connected, RipeWindow.request_rrc_list_message()) do
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
    gap_reason = if state.subscribed?, do: :replay, else: nil
    {:disconnect, disconnect(%{state | transport: transport}, gap_reason)}
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

  defp reduce_provider_frame(
         frame,
         _receipt_at,
         %State{subscribed?: false, awaiting_acknowledgements?: false} = state
       ) do
    with true <- exact_rrc_list?(frame),
         {:ok, messages} <- RipeWindow.subscription_messages(state.collectors, frame) do
      case send_json_messages(state, messages) do
        {:ok, updated} ->
          approved_collectors = Enum.map(messages, &get_in(&1, ["data", "host"]))

          pending_acknowledgements =
            approved_collectors |> Enum.map(&:crypto.hash(:sha256, &1)) |> MapSet.new()

          %{
            updated
            | window: RipeWindow.authorize(updated.window, approved_collectors),
              pending_acknowledgements: pending_acknowledgements,
              awaiting_acknowledgements?: true
          }

        {:error, failed} ->
          disconnect(failed, :transport)
      end
    else
      _invalid -> disconnect(state, :subscription)
    end
  end

  defp reduce_provider_frame(frame, receipt_at, state) do
    case subscription_acknowledgement(frame, state.pending_acknowledgements) do
      {:ok, pending_acknowledgements} ->
        complete_subscription_acknowledgement(state, pending_acknowledgements)

      :not_acknowledgement when state.subscribed? ->
        add_to_window(frame, receipt_at, state)

      :not_acknowledgement ->
        disconnect(state, :subscription)

      :invalid_acknowledgement ->
        disconnect(state, :subscription)
    end
  end

  defp subscription_acknowledgement(
         %{
           "type" => "ris_subscribe_ok",
           "data" =>
             %{
               "subscription" => %{"type" => "UPDATE", "host" => collector} = subscription,
               "socketOptions" => %{"includeRaw" => false, "acknowledge" => true} = socket_options
             } = acknowledgement
         } = frame,
         pending_acknowledgements
       )
       when map_size(frame) == 2 and map_size(acknowledgement) == 2 and
              map_size(subscription) == 2 and map_size(socket_options) == 2 and
              is_binary(collector) and byte_size(collector) in [5, 14] do
    collector_fingerprint = :crypto.hash(:sha256, collector)

    if MapSet.member?(pending_acknowledgements, collector_fingerprint) do
      {:ok, MapSet.delete(pending_acknowledgements, collector_fingerprint)}
    else
      :invalid_acknowledgement
    end
  end

  defp subscription_acknowledgement(%{"type" => "ris_subscribe_ok"}, _pending),
    do: :invalid_acknowledgement

  defp subscription_acknowledgement(_frame, _pending), do: :not_acknowledgement

  defp complete_subscription_acknowledgement(state, pending_acknowledgements) do
    if MapSet.size(pending_acknowledgements) == 0 do
      %{
        state
        | pending_acknowledgements: pending_acknowledgements,
          awaiting_acknowledgements?: false,
          subscribed?: true,
          subscription_generation: nil,
          attempt: 0
      }
    else
      %{state | pending_acknowledgements: pending_acknowledgements}
    end
  end

  defp exact_rrc_list?(%{"type" => "ris_rrc_list", "data" => collectors} = frame)
       when map_size(frame) == 2 and is_list(collectors),
       do: true

  defp exact_rrc_list?(_frame), do: false

  defp add_to_window(frame, receipt_at, state) do
    case RipeWindow.add(state.window, frame, receipt_at) do
      {:ok, window} ->
        state |> Map.put(:window, window) |> notify_observation()

      {:close_required, window} ->
        close_and_retry(frame, receipt_at, %{state | window: window})

      {:drop, reason, window} ->
        state
        |> Map.put(:window, window)
        |> record_health({:drop, provider_drop(reason)})
    end
  end

  defp close_and_retry(frame, receipt_at, state) do
    case RipeWindow.close(state.window, receipt_at) do
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
    case RipeWindow.close(state.window, now) do
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
    with {:ok, events} <- normalize_payload(payload),
         checkpoint = checkpoint(successful_at),
         :ok <- state.buffer.(events, checkpoint) do
      {:ok, maybe_record_activity(state, events)}
    else
      _failure -> {:error, state}
    end
  end

  defp normalize_payload(:empty), do: {:ok, []}

  defp normalize_payload(payload) do
    case Normalizer.ripe_window(payload) do
      {:ok, event} -> {:ok, [event]}
      {:error, _reason} -> {:error, :invalid_window}
    end
  end

  defp checkpoint(successful_at) do
    %{
      source: @source_name,
      cursor: nil,
      etag: nil,
      last_successful_at: successful_at,
      metadata: %{}
    }
  end

  defp maybe_record_activity(state, []), do: state
  defp maybe_record_activity(state, [_event]), do: record_health(state, {:activity, 1})

  defp send_json_messages(state, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn message, {:ok, current} ->
      case send_json(current, message) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, failed} -> {:halt, {:error, failed}}
      end
    end)
  end

  defp send_json(state, message) do
    case state.transport_module.send_frame(state.transport, {:text, Jason.encode!(message)}) do
      {:ok, transport} -> {:ok, %{state | transport: transport}}
      {:error, _reason, transport} -> {:error, %{state | transport: transport}}
    end
  end

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
        subscription_generation: nil,
        pending_acknowledgements: MapSet.new(),
        awaiting_acknowledgements?: false,
        subscribed?: false
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

  defp notify_observation(%State{observation_listener: {listener, marker}} = state) do
    updated = %{state | observation_listener: nil}
    send(listener, {:worldloom_provider_observation, marker})
    updated
  end

  defp notify_observation(state), do: state

  defp validate_observation_listener!(nil), do: nil

  defp validate_observation_listener!({listener, marker})
       when is_pid(listener) and is_reference(marker),
       do: {listener, marker}

  defp validate_observation_listener!(_invalid) do
    raise ArgumentError, "observation listener must contain a process and reference"
  end

  defp provider_drop(reason) when reason in [:timestamp_too_old, :timestamp_in_future],
    do: :stale

  defp provider_drop(reason) when reason in [:late_event, :window_ahead], do: :stale

  defp provider_drop(reason) when reason in [:peer_capacity, :collector_capacity],
    do: :capacity

  defp provider_drop(:unsupported_message), do: :unsupported
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
