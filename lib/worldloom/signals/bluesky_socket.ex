defmodule Worldloom.Signals.BlueskySocket do
  use GenServer

  alias Worldloom.Loom.FeedCheckpoint
  alias Worldloom.Repo
  alias Worldloom.Signals.Backoff
  alias Worldloom.Signals.BlueskyRecovery
  alias Worldloom.Signals.BlueskyWindow
  alias Worldloom.Signals.Buffer
  alias Worldloom.Signals.HealthRegistry
  alias Worldloom.Signals.Normalizer
  alias Worldloom.Signals.SafeEndpoint
  alias Worldloom.Signals.WebSocketTransport
  alias Worldloom.Signals.BlueskySocket.State

  @source :bluesky
  @source_name "bluesky"
  @flush_interval 1_000
  @upgrade_timeout 5_000
  @maximum_mailbox_depth 100
  @maximum_heap_words 2_000_000
  @fingerprint_capacity 4_096
  @collections ~w(app.bsky.feed.post app.bsky.feed.repost)
  @operations ~w(create update delete)

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

    {_replay_cursor, committed_cursor, recovery} =
      options |> initial_cursor() |> recovery_state(now)

    url = Keyword.fetch!(options, :url)
    {:ok, _uri} = SafeEndpoint.parse(url)

    state = %State{
      url: url,
      transport: nil,
      transport_module: Keyword.get(options, :transport, WebSocketTransport),
      transport_options: Keyword.get(options, :transport_options, []),
      window: BlueskyWindow.new(now),
      window_cursor: nil,
      next_window: nil,
      next_window_cursor: nil,
      next_recovery: nil,
      recovery: recovery,
      committed_cursor: committed_cursor,
      buffer: Keyword.get(options, :buffer, &Buffer.submit/2),
      health_registry: Keyword.get(options, :health_registry, HealthRegistry),
      clock: clock,
      random: Keyword.get(options, :random, &:rand.uniform/0),
      timer: Keyword.get(options, :timer, &Process.send_after/3),
      upgrade_generation: nil,
      reconnect_token: nil,
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

  defp dispatch(_message, %State{transport: nil} = state),
    do: {:noreply, state}

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
    now = state.clock.()

    {replay_cursor, committed_cursor, _fresh_recovery} =
      recovery_state(state.committed_cursor, now)

    endpoint = subscription_endpoint(state.url, replay_cursor)
    closed_state = close_transport(state)

    case state.transport_module.connect(endpoint, state.transport_options) do
      {:ok, transport} ->
        generation = make_ref()
        state.timer.(self(), {:upgrade_timeout, generation}, @upgrade_timeout)

        {:noreply,
         %{
           closed_state
           | transport: transport,
             committed_cursor: committed_cursor,
             upgrade_generation: generation,
             reconnect_token: nil
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
    updated =
      state
      |> record_health(:connected)
      |> Map.put(:attempt, 0)
      |> Map.put(:upgrade_generation, nil)

    {:continue, updated}
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

  defp reduce_provider_frame(%{"kind" => kind}, _receipt_at, state)
       when kind in ["account", "identity"],
       do: record_health(state, {:drop, :unsupported})

  defp reduce_provider_frame(frame, receipt_at, state) do
    with {:ok, cursor, identity_material} <- recovery_identity(frame),
         {:ok, target, candidate} <- route_window(state, frame, cursor, receipt_at) do
      case observe_target(state, target, cursor, identity_material) do
        {:ok, recovery} ->
          install_recovery(candidate, target, recovery)

        {:drop, :fingerprint_capacity, recovery} ->
          state
          |> install_recovery(target, recovery)
          |> mark_truncated(target, candidate)
          |> record_health({:drop, :capacity})

        {:drop, reason, recovery} ->
          state
          |> install_recovery(target, recovery)
          |> record_health({:drop, provider_drop(reason)})
      end
    else
      {:drop, reason, routed_state} ->
        routed_state
        |> record_health({:drop, provider_drop(reason)})

      {:error, reason} ->
        record_health(state, {:drop, provider_drop(reason)})
    end
  end

  defp observe_target(state, target, cursor, identity_material) do
    recovery = target_recovery(state, target)

    case BlueskyRecovery.observe(recovery, cursor, identity_material) do
      {:ok, updated} ->
        if recovery_fingerprint_count(state) >= @fingerprint_capacity do
          {:drop, :fingerprint_capacity, recovery}
        else
          {:ok, updated}
        end

      {:drop, reason, unchanged} ->
        {:drop, reason, unchanged}
    end
  end

  defp target_recovery(state, :current), do: state.recovery

  defp target_recovery(%State{next_recovery: %BlueskyRecovery{} = recovery}, :next),
    do: recovery

  defp target_recovery(state, :next), do: BlueskyRecovery.fork(state.recovery)

  defp install_recovery(state, :current, recovery), do: %{state | recovery: recovery}
  defp install_recovery(state, :next, recovery), do: %{state | next_recovery: recovery}

  defp recovery_fingerprint_count(state) do
    next_count =
      case state.next_recovery do
        %BlueskyRecovery{} = recovery -> BlueskyRecovery.fingerprint_count(recovery)
        nil -> 0
      end

    BlueskyRecovery.fingerprint_count(state.recovery) + next_count
  end

  defp route_window(state, frame, cursor, receipt_at) do
    case BlueskyWindow.add(state.window, frame, receipt_at) do
      {:ok, window} ->
        {:ok, :current,
         %{state | window: window, window_cursor: later_cursor(state.window_cursor, cursor)}}

      {:flush, _current_window, proposed_next_window} ->
        route_successor(state, frame, cursor, receipt_at, proposed_next_window)

      {:drop, reason, window} ->
        {:drop, reason, %{state | window: window}}
    end
  end

  defp route_successor(state, frame, cursor, receipt_at, proposed_next_window) do
    expected_start = DateTime.add(state.window.window_start, 4, :second)

    cond do
      DateTime.compare(proposed_next_window.window_start, expected_start) != :eq ->
        {:drop, :window_ahead, state}

      is_nil(state.next_window) ->
        {:ok, :next, %{state | next_window: proposed_next_window, next_window_cursor: cursor}}

      true ->
        case BlueskyWindow.add(state.next_window, frame, receipt_at) do
          {:ok, next_window} ->
            {:ok, :next,
             %{
               state
               | next_window: next_window,
                 next_window_cursor: later_cursor(state.next_window_cursor, cursor)
             }}

          {:flush, _next_window, _later_window} ->
            {:drop, :window_ahead, state}

          {:drop, reason, next_window} ->
            {:drop, reason, %{state | next_window: next_window}}
        end
    end
  end

  defp mark_truncated(state, :current, _candidate),
    do: %{state | window: %{state.window | truncated: true}}

  defp mark_truncated(%State{next_window: %BlueskyWindow{}} = state, :next, _candidate),
    do: %{state | next_window: %{state.next_window | truncated: true}}

  defp mark_truncated(state, :next, candidate) do
    truncated_next =
      candidate.next_window.window_start
      |> BlueskyWindow.new()
      |> Map.put(:truncated, true)

    %{state | next_window: truncated_next, next_window_cursor: nil}
  end

  defp close_elapsed_window(state, now) do
    if BlueskyWindow.elapsed?(state.window, now) do
      case persist_window(state, state.window, state.window_cursor, now) do
        {:ok, persisted} -> promote_next_window(persisted, now)
        {:error, failed} -> disconnect(failed, :persistence)
      end
    else
      state
    end
  end

  defp promote_next_window(%State{next_window: %BlueskyWindow{}} = state, _now) do
    recovery = align_recovery(state.next_recovery, state.committed_cursor)

    %{
      state
      | window: state.next_window,
        window_cursor: state.next_window_cursor,
        next_window: nil,
        next_window_cursor: nil,
        recovery: recovery,
        next_recovery: nil
    }
  end

  defp promote_next_window(state, now) do
    %{
      state
      | window: BlueskyWindow.new(now),
        window_cursor: nil,
        next_window: nil,
        next_window_cursor: nil,
        next_recovery: nil
    }
  end

  defp align_recovery(%BlueskyRecovery{} = recovery, nil), do: recovery

  defp align_recovery(%BlueskyRecovery{committed_cursor: cursor} = recovery, cursor),
    do: recovery

  defp align_recovery(%BlueskyRecovery{} = recovery, committed_cursor) do
    {:ok, advanced} = BlueskyRecovery.advance(recovery, committed_cursor)
    advanced
  end

  defp persist_window(state, window, cursor, successful_at) do
    events =
      case BlueskyWindow.flush(window) do
        :empty ->
          []

        payload ->
          case Normalizer.bluesky_window(payload) do
            {:ok, event} -> [event]
            {:error, _reason} -> :invalid
          end
      end

    if events == :invalid do
      {:error, state}
    else
      checkpoint_cursor = cursor || state.committed_cursor

      checkpoint = %{
        source: @source_name,
        cursor: encoded_cursor(checkpoint_cursor),
        etag: nil,
        last_successful_at: successful_at,
        metadata: %{}
      }

      case state.buffer.(events, checkpoint) do
        :ok ->
          updated =
            state
            |> commit_recovery(checkpoint_cursor)
            |> maybe_record_activity(events)

          {:ok, updated}

        {:error, _reason} ->
          {:error, state}
      end
    end
  end

  defp commit_recovery(state, nil), do: state

  defp commit_recovery(state, cursor) do
    cond do
      is_integer(state.committed_cursor) and cursor <= state.committed_cursor ->
        state

      true ->
        {:ok, recovery} = BlueskyRecovery.commit(state.recovery, cursor)
        %{state | committed_cursor: cursor, recovery: recovery}
    end
  end

  defp maybe_record_activity(state, []), do: state
  defp maybe_record_activity(state, [_event]), do: record_health(state, {:activity, 1})

  defp recovery_identity(%{
         "kind" => "commit",
         "time_us" => cursor,
         "did" => did,
         "commit" => %{
           "collection" => collection,
           "operation" => operation,
           "rkey" => record_key
         }
       })
       when is_integer(cursor) and cursor >= 0 and is_binary(did) and byte_size(did) in 1..2_048 and
              collection in @collections and operation in @operations and
              is_binary(record_key) and byte_size(record_key) in 1..512 do
    {:ok, cursor, Jason.encode!([cursor, "commit", did, collection, operation, record_key])}
  end

  defp recovery_identity(_frame), do: {:error, :invalid_identity}

  defp subscription_endpoint(url, replay_cursor) do
    {:ok, uri} = SafeEndpoint.parse(url)

    parameters = [
      {"wantedCollections", "app.bsky.feed.post"},
      {"wantedCollections", "app.bsky.feed.repost"},
      {"maxMessageSizeBytes", "262144"},
      {"compress", "false"}
    ]

    parameters =
      if is_integer(replay_cursor),
        do: parameters ++ [{"cursor", Integer.to_string(replay_cursor)}],
        else: parameters

    %{uri | userinfo: nil, query: URI.encode_query(parameters, :rfc3986), fragment: nil}
    |> URI.to_string()
  end

  defp recovery_state(committed_cursor, now) do
    case BlueskyRecovery.new(committed_cursor, now) do
      {:replay, cursor, recovery} -> {cursor, committed_cursor, recovery}
      {:live_tail, _gap, recovery} -> {nil, nil, recovery}
    end
  end

  defp initial_cursor(options) do
    checkpoint_cursor =
      if Keyword.has_key?(options, :committed_cursor) do
        Keyword.get(options, :committed_cursor)
      else
        case Repo.get(FeedCheckpoint, @source_name) do
          nil -> nil
          checkpoint -> checkpoint.cursor
        end
      end

    parse_cursor(checkpoint_cursor)
  end

  defp parse_cursor(nil), do: nil
  defp parse_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: cursor

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {parsed, ""} when parsed >= 0 -> parsed
      _invalid -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil
  defp encoded_cursor(nil), do: nil
  defp encoded_cursor(cursor), do: Integer.to_string(cursor)
  defp later_cursor(nil, cursor), do: cursor
  defp later_cursor(existing, cursor), do: max(existing, cursor)

  defp disconnect(state, drop_reason) do
    disconnected = close_transport(state)

    disconnected =
      if drop_reason, do: record_health(disconnected, {:drop, drop_reason}), else: disconnected

    disconnected |> record_health(:disconnected) |> schedule_reconnect()
  end

  defp close_transport(%State{transport: nil} = state), do: state

  defp close_transport(state) do
    state.transport_module.close(state.transport)
    %{state | transport: nil, upgrade_generation: nil}
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

  defp provider_drop(reason) when reason in [:duplicate, :committed],
    do: if(reason == :duplicate, do: :duplicate, else: :replay)

  defp provider_drop(reason) when reason in [:timestamp_too_old, :timestamp_in_future], do: :stale

  defp provider_drop(reason) when reason in [:late_event, :window_ahead], do: :stale

  defp provider_drop(reason)
       when reason in [:unsupported_kind, :unsupported_collection, :unsupported_operation],
       do: :unsupported

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
