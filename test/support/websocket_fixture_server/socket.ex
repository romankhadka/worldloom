defmodule Worldloom.TestSupport.WebSocketFixtureServer.Socket do
  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test_process, {:fixture_connected, self()})
    {:ok, state}
  end

  @impl true
  def handle_in({payload, [opcode: opcode]}, state) do
    send(state.test_process, {:fixture_frame, opcode, payload})
    {:ok, state}
  end

  @impl true
  def handle_control({payload, [opcode: opcode]}, state) do
    send(state.test_process, {:fixture_control, opcode, payload})
    {:ok, state}
  end

  @impl true
  def handle_info({:push, frame}, state), do: {:push, frame, state}

  def handle_info({:push_many, frames}, state) when is_list(frames),
    do: {:push, frames, state}

  def handle_info({:close, code, reason}, state),
    do: {:stop, :normal, {code, reason}, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    send(state.test_process, {:fixture_closed, reason})
    :ok
  end
end
