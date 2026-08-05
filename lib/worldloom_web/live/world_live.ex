defmodule WorldloomWeb.WorldLive do
  use WorldloomWeb, :live_view

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.Event
  alias Worldloom.Loom.GesturePolicy
  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.Store
  alias Worldloom.Signals.HealthMonitor
  alias WorldloomWeb.Presence

  @initial_history_limit 400
  @historical_window_limit 500
  @maximum_window 600
  @history_page_limit 400
  @history_throttle_ms 500
  @accessible_limit 20
  @public_scaffold_limit 12

  @impl true
  def mount(_params, session, socket) do
    action = socket.assigns.live_action
    feed_health = HealthMonitor.current()

    socket =
      socket
      |> assign(:page_title, page_title(action))
      |> assign(:utc_chapter, utc_chapter([], nil))
      |> assign(:live?, action == :live)
      |> assign(:mode, action)
      |> assign(:instructions, [])
      |> assign(:scaffold, [])
      |> assign(:ambient, nil)
      |> assign(:trusted_events, %{})
      |> assign(:oldest_loaded_sequence, nil)
      |> assign(:history_requested_at, nil)
      |> assign(:selected_event, nil)
      |> assign(:selected_detail, nil)
      |> assign(:gesture_lane, 0.5)
      |> assign(:gesture_status, route_gesture_status(action))
      |> assign(:cooldown_until, nil)
      |> assign(:cooldown_token, nil)
      |> assign(:cooldown_seconds, nil)
      |> assign(:cooldown_status, nil)
      |> assign(:at_live_edge, action == :live)
      |> assign(:permalink, nil)
      |> assign(:current_url, nil)
      |> assign(:feed_health, feed_health)
      |> assign(:viewer_count, Presence.viewer_count())
      |> assign(:visitor_identity, session["visitor_identity"] || session[:visitor_identity])
      |> assign(:peer_address, peer_address(socket))
      |> stream(:archive_rows, [], dom_id: &chapter_dom_id/1)
      |> stream(:accessible_formations, [], dom_id: &formation_dom_id/1)

    if connected?(socket) do
      subscribe(action == :live)
      presence_key = random_presence_key()
      {:ok, _metadata} = Presence.track(self(), Presence.topic(), presence_key, %{})
      {:ok, assign(socket, :viewer_count, Presence.viewer_count())}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      case socket.assigns.live_action do
        :live -> enter_live_route(socket, uri)
        :chapter -> enter_chapter_route(socket, params, uri)
        action -> enter_panel_route(socket, action, uri)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:loom_event, instruction}, %{assigns: %{live?: true}} = socket) do
    socket =
      case Store.fetch(instruction["sequence"]) do
        {:ok, event} ->
          socket
          |> assign(:trusted_events, bounded_events(socket.assigns.trusted_events, [event]))
          |> stream_insert(:accessible_formations, instruction, at: -1, limit: -@accessible_limit)

        :error ->
          socket
      end

    {:noreply, push_event(socket, "worldloom:event", instruction)}
  end

  def handle_info({:loom_event, _instruction}, socket), do: {:noreply, socket}

  def handle_info({:feed_health, health}, socket) do
    {:noreply, assign(socket, :feed_health, health)}
  end

  def handle_info({:gesture_ready, token}, %{assigns: %{cooldown_token: token}} = socket),
    do: {:noreply, clear_gesture_cooldown(socket)}

  def handle_info({:gesture_ready, _stale_token}, socket), do: {:noreply, socket}
  def handle_info(:gesture_ready, socket), do: {:noreply, clear_gesture_cooldown(socket)}

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: topic, event: "presence_diff"},
        socket
      ) do
    if topic == Presence.topic() do
      viewer_count = Presence.viewer_count()

      {:noreply,
       socket
       |> assign(:viewer_count, viewer_count)
       |> push_event("worldloom:presence", %{viewer_count: viewer_count})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "sequence-gap",
        %{"after" => after_sequence, "through" => through_sequence},
        socket
      )
      when is_integer(after_sequence) and is_integer(through_sequence) and
             after_sequence >= 0 and through_sequence >= after_sequence do
    if through_sequence - after_sequence > @maximum_window do
      events = Store.latest(@initial_history_limit)
      instructions = Enum.map(events, &Instruction.from_event/1)
      scaffold = public_scaffold(events, nil)
      ambient = ambient_instruction(events, nil)

      {:noreply,
       socket
       |> assign(:trusted_events, trusted_event_map(events))
       |> push_event("worldloom:reload", %{
         instructions: instructions,
         scaffold: scaffold,
         ambient: ambient,
         watermark: Store.highest_sequence()
       })}
    else
      events = Store.after(after_sequence, through_sequence, @maximum_window)
      instructions = Enum.map(events, &Instruction.from_event/1)

      socket =
        Enum.reduce(instructions, socket, fn instruction, updated_socket ->
          stream_insert(updated_socket, :accessible_formations, instruction,
            at: -1,
            limit: -@accessible_limit
          )
        end)

      {:noreply,
       socket
       |> assign(:trusted_events, bounded_events(socket.assigns.trusted_events, events))
       |> push_event("worldloom:catch-up", %{
         instructions: instructions,
         watermark: through_sequence
       })}
    end
  end

  def handle_event("sequence-gap", _payload, socket), do: {:noreply, socket}

  def handle_event("history-before", _payload, socket) do
    now_ms = System.monotonic_time(:millisecond)

    if history_request_allowed?(socket.assigns.history_requested_at, now_ms) do
      events = history_before(socket.assigns.oldest_loaded_sequence)
      instructions = Enum.map(events, &Instruction.from_event/1)

      {:noreply,
       socket
       |> assign(:history_requested_at, now_ms)
       |> assign(:oldest_loaded_sequence, older_sequence(events, socket))
       |> assign(:trusted_events, bounded_events(socket.assigns.trusted_events, events))
       |> push_event("worldloom:history", %{
         instructions: instructions,
         scaffold: public_scaffold(events, nil),
         archive_start?: length(events) < @history_page_limit
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("lane-key", %{"key" => key}, socket)
      when key in ["ArrowUp", "ArrowRight", "ArrowDown", "ArrowLeft"] do
    direction = if key in ["ArrowUp", "ArrowRight"], do: 1, else: -1
    lane = socket.assigns.gesture_lane |> Kernel.+(direction * 0.05) |> clamp_lane()
    {:noreply, assign(socket, :gesture_lane, lane)}
  end

  def handle_event("lane-key", _payload, socket), do: {:noreply, socket}

  def handle_event("lane-change", %{"lane" => encoded_lane}, socket) do
    case Float.parse(encoded_lane) do
      {lane, ""} -> {:noreply, assign(socket, :gesture_lane, clamp_lane(lane))}
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("viewport-state", %{"at_live_edge" => at_live_edge}, socket)
      when is_boolean(at_live_edge) do
    {:noreply, assign(socket, :at_live_edge, at_live_edge)}
  end

  def handle_event("viewport-state", _payload, socket), do: {:noreply, socket}

  def handle_event(
        "weave-gesture",
        %{"gesture" => gesture, "lane" => encoded_lane},
        socket
      )
      when gesture in ["tug", "knot", "illuminate"] and is_binary(encoded_lane) do
    case Float.parse(encoded_lane) do
      {lane, ""} ->
        lane = clamp_lane(lane)

        commit_gesture(
          %{"gesture" => gesture, "lane" => lane},
          assign(socket, :gesture_lane, lane)
        )

      _invalid ->
        {:noreply, assign(socket, :gesture_status, "Choose a valid gesture and lane.")}
    end
  end

  def handle_event("weave-gesture", _payload, socket) do
    {:noreply, assign(socket, :gesture_status, "Choose a valid gesture and lane.")}
  end

  def handle_event("gesture", payload, socket), do: commit_gesture(payload, socket)

  def handle_event("return-live", _payload, socket) do
    events = Store.latest(@initial_history_limit)
    instructions = Enum.map(events, &Instruction.from_event/1)
    scaffold = public_scaffold(events, nil)
    ambient = ambient_instruction(events, nil)

    {:noreply,
     socket
     |> assign(:at_live_edge, true)
     |> assign(:trusted_events, trusted_event_map(events))
     |> push_event("worldloom:return-live", %{
       instructions: instructions,
       scaffold: scaffold,
       ambient: ambient,
       watermark: Store.highest_sequence()
     })}
  end

  def handle_event("select-formation", %{"sequence" => sequence}, socket)
      when is_integer(sequence) and sequence > 0 do
    select_formation(sequence, socket)
  end

  def handle_event("select-formation", %{"sequence" => encoded_sequence}, socket)
      when is_binary(encoded_sequence) do
    case Integer.parse(encoded_sequence) do
      {sequence, ""} when sequence > 0 -> select_formation(sequence, socket)
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("select-formation", _payload, socket), do: {:noreply, socket}

  def handle_event("clear-selection", _payload, socket) do
    {:noreply, assign(socket, selected_event: nil, selected_detail: nil)}
  end

  def handle_event("share", _payload, socket) do
    absolute_url =
      WorldloomWeb.Endpoint.url()
      |> Kernel.<>("/")
      |> URI.merge(socket.assigns.permalink)
      |> URI.to_string()

    {:noreply, push_event(socket, "worldloom:copy-link", %{url: absolute_url})}
  end

  defp select_formation(sequence, socket) do
    case Map.fetch(socket.assigns.trusted_events, sequence) do
      {:ok, event} ->
        permalink = event_permalink(event)

        {:noreply,
         socket
         |> assign(:selected_event, event)
         |> assign(:selected_detail, safe_detail(event))
         |> assign(:permalink, permalink)
         |> push_patch(to: permalink)}

      :error ->
        {:noreply, socket}
    end
  end

  defp commit_gesture(payload, socket) do
    context = [
      identity: socket.assigns.visitor_identity,
      peer_address: socket.assigns.peer_address,
      live_edge?: socket.assigns.live? and socket.assigns.at_live_edge
    ]

    case GesturePolicy.commit(payload, context) do
      {:ok, committed_event} ->
        {:noreply,
         socket
         |> begin_gesture_cooldown(30, "Gesture joined the living edge.")
         |> push_event("worldloom:gesture-accepted", %{"sequence" => committed_event.id})}

      {:error, reason, retry_after_seconds} ->
        {:noreply, apply_gesture_failure(socket, reason, retry_after_seconds)}
    end
  end

  defp apply_gesture_failure(socket, reason, retry_after_seconds)
       when reason in [:cooldown, :rate_limited] and is_integer(retry_after_seconds) and
              retry_after_seconds > 0 do
    begin_gesture_cooldown(
      socket,
      retry_after_seconds,
      gesture_error_message(reason, retry_after_seconds)
    )
  end

  defp apply_gesture_failure(socket, reason, retry_after_seconds) do
    assign(socket, :gesture_status, gesture_error_message(reason, retry_after_seconds))
  end

  defp begin_gesture_cooldown(socket, seconds, status) do
    token = make_ref()
    Process.send_after(self(), {:gesture_ready, token}, :timer.seconds(seconds))

    assign(socket,
      gesture_status: status,
      cooldown_until: DateTime.add(DateTime.utc_now(), seconds, :second),
      cooldown_token: token,
      cooldown_seconds: seconds,
      cooldown_status: status
    )
  end

  defp clear_gesture_cooldown(socket) do
    assign(socket,
      cooldown_until: nil,
      cooldown_token: nil,
      cooldown_seconds: nil,
      cooldown_status: nil,
      gesture_status: route_gesture_status(socket.assigns.mode)
    )
  end

  defp load_events(:chapter, %{"date" => encoded_date, "sequence" => encoded_sequence}) do
    with {:ok, date} <- Date.from_iso8601(encoded_date),
         {sequence, ""} when sequence > 0 <- Integer.parse(encoded_sequence),
         {:ok, event} <- Store.fetch(sequence),
         true <- DateTime.to_date(event.occurred_at) == date do
      {Store.around(sequence, @historical_window_limit), event}
    else
      _invalid_permalink -> raise Ecto.NoResultsError, queryable: Event
    end
  end

  defp enter_live_route(socket, uri) do
    socket = transition_coordinator_subscription(socket, true)
    events = Store.latest(@initial_history_limit)
    route_changed? = route_changed?(socket, uri)

    socket =
      socket
      |> assign(:page_title, page_title(:live))
      |> assign(:live?, true)
      |> assign(:mode, :live)
      |> assign(:at_live_edge, true)
      |> assign(:selected_event, nil)
      |> assign(:selected_detail, nil)
      |> assign(:permalink, URI.parse(uri).path || "/")
      |> assign(:current_url, uri)
      |> restore_live_gesture_state()
      |> assign_event_window(events, nil)

    if route_changed? do
      push_event(socket, "worldloom:return-live", %{
        instructions: socket.assigns.instructions,
        scaffold: socket.assigns.scaffold,
        ambient: encode_ambient(socket.assigns.ambient),
        watermark: instruction_watermark(socket.assigns.instructions)
      })
    else
      socket
    end
  end

  defp enter_chapter_route(socket, params, uri) do
    socket = transition_coordinator_subscription(socket, false)
    {events, selected_event} = load_events(:chapter, params)
    route_changed? = route_changed?(socket, uri)

    socket =
      socket
      |> assign(:page_title, page_title(:chapter))
      |> assign(:live?, false)
      |> assign(:mode, :chapter)
      |> assign(:at_live_edge, false)
      |> assign(:gesture_status, route_gesture_status(:chapter))
      |> assign(:selected_event, selected_event)
      |> assign(:selected_detail, safe_detail(selected_event))
      |> assign(:permalink, event_permalink(selected_event))
      |> assign(:current_url, uri)
      |> assign_event_window(events, selected_event)

    if route_changed? do
      push_event(socket, "worldloom:reload", %{
        instructions: socket.assigns.instructions,
        scaffold: socket.assigns.scaffold,
        ambient: encode_ambient(socket.assigns.ambient),
        watermark: instruction_watermark(socket.assigns.instructions),
        selected_sequence: selected_event.id
      })
    else
      socket
    end
  end

  defp enter_panel_route(socket, action, uri) do
    socket = transition_coordinator_subscription(socket, false)
    events = Store.latest(@initial_history_limit)
    chapters = if action == :archive, do: Store.chapters(), else: []
    route_changed? = route_changed?(socket, uri)

    socket =
      socket
      |> assign(:page_title, page_title(action))
      |> assign(:live?, false)
      |> assign(:mode, action)
      |> assign(:at_live_edge, false)
      |> assign(:gesture_status, route_gesture_status(action))
      |> assign(:selected_event, nil)
      |> assign(:selected_detail, nil)
      |> assign(:current_url, uri)
      |> assign(:permalink, URI.parse(uri).path)
      |> assign_event_window(events, nil)
      |> stream(:archive_rows, chapters, reset: true)

    if route_changed? do
      push_event(socket, "worldloom:reload", %{
        instructions: socket.assigns.instructions,
        scaffold: socket.assigns.scaffold,
        ambient: encode_ambient(socket.assigns.ambient),
        watermark: instruction_watermark(socket.assigns.instructions)
      })
    else
      socket
    end
  end

  defp assign_event_window(socket, events, selected_event) do
    instructions = Enum.map(events, &Instruction.from_event/1)

    socket
    |> assign(:utc_chapter, utc_chapter(events, selected_event))
    |> assign(:instructions, instructions)
    |> assign(:scaffold, public_scaffold(events, selected_event))
    |> assign(:ambient, ambient_event(events, selected_event))
    |> assign(:trusted_events, trusted_event_map(events))
    |> assign(:oldest_loaded_sequence, oldest_sequence(events))
    |> assign(:history_requested_at, nil)
    |> stream(:accessible_formations, Enum.take(instructions, -@accessible_limit), reset: true)
  end

  defp public_scaffold([], _selected_event), do: []

  defp public_scaffold(events, selected_event) do
    (selected_event || List.last(events)).id
    |> Store.wikimedia_before(@public_scaffold_limit)
    |> Enum.map(&Instruction.from_event/1)
  end

  defp ambient_instruction(events, selected_event) do
    events
    |> ambient_event(selected_event)
    |> encode_ambient()
  end

  defp encode_ambient(nil), do: nil
  defp encode_ambient(event), do: Instruction.from_event(event)

  defp transition_coordinator_subscription(socket, live?) do
    if connected?(socket) do
      cond do
        live? and not socket.assigns.live? ->
          Phoenix.PubSub.subscribe(Worldloom.PubSub, Coordinator.topic())

        not live? and socket.assigns.live? ->
          Phoenix.PubSub.unsubscribe(Worldloom.PubSub, Coordinator.topic())

        true ->
          :ok
      end
    end

    socket
  end

  defp route_changed?(socket, uri) do
    connected?(socket) and not is_nil(socket.assigns.current_url) and
      URI.parse(socket.assigns.current_url).path != URI.parse(uri).path
  end

  defp restore_live_gesture_state(socket) do
    case remaining_cooldown_seconds(socket.assigns.cooldown_until) do
      nil ->
        assign(socket,
          cooldown_until: nil,
          cooldown_token: nil,
          cooldown_seconds: nil,
          cooldown_status: nil,
          gesture_status: route_gesture_status(:live)
        )

      remaining_seconds ->
        assign(socket,
          cooldown_seconds: remaining_seconds,
          gesture_status: socket.assigns.cooldown_status
        )
    end
  end

  defp remaining_cooldown_seconds(nil), do: nil

  defp remaining_cooldown_seconds(cooldown_until) do
    remaining_milliseconds = DateTime.diff(cooldown_until, DateTime.utc_now(), :millisecond)

    if remaining_milliseconds > 0 do
      div(remaining_milliseconds + 999, 1_000)
    end
  end

  defp instruction_watermark([]), do: 0
  defp instruction_watermark(instructions), do: List.last(instructions)["sequence"]

  defp ambient_event([], _selected_event), do: nil

  defp ambient_event(events, selected_event) do
    (selected_event || List.last(events)).id
    |> Store.ambient_before()
  end

  defp subscribe(live?) do
    Phoenix.PubSub.subscribe(Worldloom.PubSub, Presence.topic())
    Phoenix.PubSub.subscribe(Worldloom.PubSub, HealthMonitor.topic())
    if live?, do: Phoenix.PubSub.subscribe(Worldloom.PubSub, Coordinator.topic())
  end

  defp peer_address(socket) do
    if connected?(socket) do
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _missing -> nil
      end
    end
  end

  defp bounded_events(existing_events, new_events) do
    existing_events
    |> Map.values()
    |> Kernel.++(new_events)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
    |> Enum.take(-@maximum_window)
    |> trusted_event_map()
  end

  defp history_before(nil), do: []
  defp history_before(sequence), do: Store.before(sequence, @history_page_limit)
  defp history_request_allowed?(nil, _now_ms), do: true

  defp history_request_allowed?(requested_at, now_ms),
    do: now_ms - requested_at >= @history_throttle_ms

  defp older_sequence([], socket), do: socket.assigns.oldest_loaded_sequence
  defp older_sequence(events, _socket), do: oldest_sequence(events)
  defp oldest_sequence([]), do: nil
  defp oldest_sequence([event | _events]), do: event.id
  defp trusted_event_map(events), do: Map.new(events, &{&1.id, &1})
  defp formation_dom_id(instruction), do: "formation-#{instruction["sequence"]}"
  defp chapter_dom_id(chapter), do: "chapter-#{Date.to_iso8601(chapter.date)}"

  defp random_presence_key do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp page_title(:live), do: "Live weave"
  defp page_title(:archive), do: "UTC chapters"
  defp page_title(:chapter), do: "Historical formation"
  defp page_title(:about), do: "About Worldloom"
  defp route_gesture_status(:live), do: "Choose an action for the live edge."
  defp route_gesture_status(_action), do: "Return to the live edge to contribute."

  defp utc_chapter([], _selected_event), do: Date.utc_today() |> Date.to_iso8601()

  defp utc_chapter(events, selected_event) do
    (selected_event || List.last(events)).occurred_at
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp safe_detail(nil), do: nil

  defp safe_detail(event) do
    %{
      sequence: event.id,
      kind: event.kind,
      source: event.source,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      summary: event.payload["summary"]
    }
  end

  defp event_permalink(nil), do: nil

  defp event_permalink(event) do
    "/chapters/#{Date.to_iso8601(DateTime.to_date(event.occurred_at))}/#{event.id}"
  end

  defp clamp_lane(lane), do: lane |> max(0.0) |> min(1.0) |> Float.round(2)
  defp gesture_description("tug"), do: "Bend a strand"
  defp gesture_description("knot"), do: "Join two paths"
  defp gesture_description("illuminate"), do: "Awaken a junction"
  defp gesture_error_message(:invalid, _retry), do: "Choose a valid gesture and lane."
  defp gesture_error_message(:not_live, _retry), do: "Return to the live edge to contribute."
  defp gesture_error_message(:cooldown, retry), do: "Try again in #{retry} seconds."

  defp gesture_error_message(:rate_limited, retry),
    do: "The loom is busy. Try again in #{retry} seconds."

  defp gesture_error_message(_reason, _retry), do: "The gesture is unavailable right now."
end
