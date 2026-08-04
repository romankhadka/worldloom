defmodule Worldloom.Loom.Coordinator do
  use GenServer

  alias Worldloom.Loom.Instruction
  alias Worldloom.Loom.Store

  @topic "loom:events"
  @call_timeout 15_000
  @start_count_key {__MODULE__, :start_count}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)

    state = %{
      store: Keyword.get(options, :store, Store),
      pubsub: Keyword.get(options, :pubsub, Worldloom.PubSub),
      topic: Keyword.get(options, :topic, @topic)
    }

    GenServer.start_link(__MODULE__, state, registration_options(name))
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec commit_external(GenServer.server(), [term()], map()) :: {:ok, [term()]} | {:error, term()}
  def commit_external(server \\ __MODULE__, events, checkpoint),
    do: GenServer.call(server, {:external, events, checkpoint}, @call_timeout)

  @spec commit_visitor(GenServer.server(), term(), String.t()) :: {:ok, term()} | {:error, term()}
  def commit_visitor(server \\ __MODULE__, event, request_nonce),
    do: GenServer.call(server, {:visitor, event, request_nonce}, @call_timeout)

  @spec highest_sequence(GenServer.server()) :: non_neg_integer()
  def highest_sequence(server \\ __MODULE__), do: GenServer.call(server, :highest_sequence)

  @spec start_count() :: non_neg_integer()
  def start_count, do: :persistent_term.get(@start_count_key, 0)

  @impl true
  def init(state) do
    initialized_state = Map.put(state, :highest_sequence, state.store.highest_sequence())
    :persistent_term.put(@start_count_key, start_count() + 1)
    :telemetry.execute([:worldloom, :loom, :coordinator, :start], %{count: 1}, %{})
    {:ok, initialized_state}
  end

  @impl true
  def handle_call({:external, events, checkpoint}, _from, state) do
    commit(state, :external, fn -> state.store.commit_external(events, checkpoint) end)
  end

  def handle_call({:visitor, event, request_nonce}, _from, state) do
    commit(state, :visitor, fn -> state.store.commit_visitor(event, request_nonce) end)
  end

  def handle_call(:highest_sequence, _from, state) do
    {:reply, state.highest_sequence, state}
  end

  defp commit(state, kind, operation) do
    started_at = System.monotonic_time()

    case operation.() do
      {:ok, events} when is_list(events) ->
        updated_state = publish_committed(events, state)

        emit_commit_telemetry(
          started_at,
          kind,
          :ok,
          length(events),
          updated_state.highest_sequence
        )

        {:reply, {:ok, events}, updated_state}

      {:ok, event} ->
        updated_state = publish_committed([event], state)
        emit_commit_telemetry(started_at, kind, :ok, 1, updated_state.highest_sequence)
        {:reply, {:ok, event}, updated_state}

      {:error, _reason} = error ->
        emit_commit_telemetry(started_at, kind, :error, 0, state.highest_sequence)
        {:reply, error, state}
    end
  end

  defp publish_committed(events, state) do
    Enum.each(events, fn event ->
      instruction = Instruction.from_event(event)
      :ok = Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:loom_event, instruction})
    end)

    highest_sequence =
      Enum.reduce(events, state.highest_sequence, fn event, highest_sequence ->
        max(event.id, highest_sequence)
      end)

    %{state | highest_sequence: highest_sequence}
  end

  defp emit_commit_telemetry(started_at, kind, status, count, highest_sequence) do
    :telemetry.execute(
      [:worldloom, :loom, :commit],
      %{
        duration: System.monotonic_time() - started_at,
        count: count,
        highest_sequence: highest_sequence
      },
      %{kind: kind, status: status}
    )
  end

  defp registration_options(nil), do: []
  defp registration_options(name), do: [name: name]
end
