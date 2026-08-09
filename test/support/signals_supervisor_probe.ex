defmodule Worldloom.TestSupport.SignalsSupervisorProbe do
  use GenServer

  def start_link({name, test_process}) do
    GenServer.start_link(__MODULE__, test_process, name: name)
  end

  @impl true
  def init(test_process) do
    send(test_process, {:started, self()})
    {:ok, nil}
  end
end
