defmodule Worldloom.TestSupport.FakeDrandClient do
  @json_safe_max 9_007_199_254_740_991

  def child_spec(options) do
    %{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  def start_link(options) do
    Agent.start_link(fn ->
      %{
        owner: Keyword.fetch!(options, :owner),
        schedule: Keyword.get(options, :schedule),
        responses: Keyword.get(options, :responses, %{}),
        new_responses: Keyword.get(options, :new_responses, [])
      }
    end)
  end

  def new(options) do
    factory = Keyword.fetch!(options, :factory)

    Agent.get_and_update(factory, fn state ->
      send(state.owner, :drand_client_new)
      {response, remaining} = pop_response(state.new_responses, {:error, :unavailable})
      {response, %{state | new_responses: remaining}}
    end)
  end

  def schedule(client), do: Agent.get(client, & &1.schedule)

  def fetch_round(client, round) when is_integer(round) and round in 1..@json_safe_max do
    Agent.get_and_update(client, fn state ->
      send(state.owner, {:drand_fetch, round})
      scripted = Map.get(state.responses, round, :ok)
      {response, remaining} = pop_response(scripted, :ok)
      responses = Map.put(state.responses, round, remaining)
      {resolve(response, round), %{state | responses: responses}}
    end)
  end

  defp pop_response([response | remaining], _default), do: {response, remaining}
  defp pop_response([], default), do: {default, []}
  defp pop_response(response, _default), do: {response, response}

  defp resolve(:ok, round) do
    render_identity =
      :sha256
      |> :crypto.hash(Integer.to_string(round))
      |> Base.encode16(case: :lower)

    {:ok, %{round: round, render_identity: render_identity}}
  end

  defp resolve(response, _round), do: response
end
