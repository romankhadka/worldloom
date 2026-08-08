defmodule Worldloom.Loom.CoordinatorTestStore do
  alias Worldloom.Loom.LiveSnapshot
  alias Worldloom.Repo

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    Agent.start_link(
      fn ->
        %{
          calls: [],
          delegate: Keyword.get(options, :delegate),
          external_results: Keyword.get(options, :external_results, []),
          repo: Keyword.get(options, :repo),
          visitor_results: Keyword.get(options, :visitor_results, []),
          snapshots: Keyword.get(options, :snapshots, []),
          highest_sequence: Keyword.get(options, :highest_sequence, 0)
        }
      end,
      name: __MODULE__
    )
  end

  @spec calls() :: [term()]
  def calls do
    Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
  end

  @spec commit_external([term()], map()) :: {:ok, [term()]} | {:error, term()}
  def commit_external(events, checkpoint) do
    call = {:commit_external, events, checkpoint}

    case delegate_configuration() do
      {nil, _repo} ->
        take_result(:external_results, call, :commit_external_returned)

      {delegate, repo} ->
        result = with_repo(repo, fn -> delegate.commit_external(events, checkpoint) end)
        record_result(call, :commit_external_returned, result)
        result
    end
  end

  @spec commit_visitor(term(), String.t()) :: {:ok, term()} | {:error, term()}
  def commit_visitor(event, request_nonce) do
    call = {:commit_visitor, event, request_nonce}

    case delegate_configuration() do
      {nil, _repo} ->
        take_result(:visitor_results, call, :commit_visitor_returned)

      {delegate, repo} ->
        result = with_repo(repo, fn -> delegate.commit_visitor(event, request_nonce) end)
        record_result(call, :commit_visitor_returned, result)
        result
    end
  end

  @spec live_snapshot(DateTime.t() | nil) :: LiveSnapshot.t()
  def live_snapshot(previous_window_end) do
    case delegate_configuration() do
      {nil, _repo} ->
        Agent.get_and_update(__MODULE__, fn state ->
          case state.snapshots do
            [%LiveSnapshot{} = snapshot | remaining_snapshots] ->
              {
                snapshot,
                %{
                  state
                  | calls: [{:live_snapshot, previous_window_end} | state.calls],
                    snapshots: remaining_snapshots
                }
              }

            [] ->
              raise "no live snapshot configured for #{inspect(previous_window_end)}"
          end
        end)

      {delegate, repo} ->
        snapshot = with_repo(repo, fn -> delegate.live_snapshot(previous_window_end) end)
        record_call({:live_snapshot, previous_window_end})
        snapshot
    end
  end

  @spec highest_sequence() :: non_neg_integer()
  def highest_sequence do
    case delegate_configuration() do
      {nil, _repo} ->
        Agent.get_and_update(__MODULE__, fn state ->
          {state.highest_sequence, %{state | calls: [:highest_sequence | state.calls]}}
        end)

      {delegate, repo} ->
        sequence = with_repo(repo, fn -> delegate.highest_sequence() end)
        record_call(:highest_sequence)
        sequence
    end
  end

  defp delegate_configuration do
    Agent.get(__MODULE__, fn state -> {state.delegate, state.repo} end)
  end

  defp with_repo(nil, operation), do: operation.()

  defp with_repo(repo, operation) do
    Repo.put_dynamic_repo(repo)
    operation.()
  end

  defp record_call(call) do
    Agent.update(__MODULE__, fn state -> %{state | calls: [call | state.calls]} end)
  end

  defp record_result(call, returned, result) do
    Agent.update(__MODULE__, fn state ->
      %{state | calls: [{returned, result}, call | state.calls]}
    end)
  end

  defp take_result(queue, call, returned) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch!(state, queue) do
        [result | remaining_results] ->
          calls = [{returned, result}, call | state.calls]
          {result, state |> Map.put(queue, remaining_results) |> Map.put(:calls, calls)}

        [] ->
          raise "no #{queue} configured"
      end
    end)
  end
end
