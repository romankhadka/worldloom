defmodule Worldloom.Signals.SupervisorTest do
  use ExUnit.Case, async: true

  alias Worldloom.Signals.Supervisor, as: SignalsSupervisor

  defmodule Probe do
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

  test "restarts one failed feed without restarting its sibling" do
    first_name = unique_name(:first)
    second_name = unique_name(:second)

    children = [
      %{id: :first, start: {Probe, :start_link, [{first_name, self()}]}},
      %{id: :second, start: {Probe, :start_link, [{second_name, self()}]}}
    ]

    {:ok, supervisor} = SignalsSupervisor.start_link(name: nil, children: children)

    assert_receive {:started, first_pid}, 500
    assert_receive {:started, second_pid}, 500
    Process.exit(first_pid, :kill)
    assert_receive {:started, restarted_first_pid}, 500

    assert restarted_first_pid != first_pid
    assert Process.whereis(first_name) == restarted_first_pid
    assert Process.whereis(second_name) == second_pid
    assert Process.alive?(supervisor)
  end

  test "starts no feed children when ingestion is disabled" do
    {:ok, supervisor} =
      SignalsSupervisor.start_link(name: nil, config: [enabled: false])

    assert Supervisor.which_children(supervisor) == []
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
