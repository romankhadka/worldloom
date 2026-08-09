defmodule Worldloom.TestSupport.FakeWebSocketTransport do
  defstruct [:id, :owner, connected?: false, closed?: false]

  def connect(endpoint, options) do
    owner = Keyword.fetch!(options, :owner)
    id = make_ref()
    send(owner, {:transport_connect, endpoint, id})
    {:ok, %__MODULE__{id: id, owner: owner}}
  end

  def stream(%__MODULE__{id: id} = transport, {:fake_socket, id, events})
      when is_list(events) do
    connected? = transport.connected? or :connected in events
    {:ok, %{transport | connected?: connected?}, events}
  end

  def stream(%__MODULE__{id: id} = transport, {:fake_error, id, reason}),
    do: {:error, reason, transport}

  def stream(%__MODULE__{}, _message), do: :unknown

  def send_frame(%__MODULE__{} = transport, frame) do
    send(transport.owner, {:transport_sent, transport.id, frame})
    {:ok, transport}
  end

  def acknowledge_close(%__MODULE__{} = transport, code) do
    send(transport.owner, {:transport_acknowledged_close, transport.id, code})
    {:ok, close(transport)}
  end

  def close(%__MODULE__{closed?: true} = transport), do: transport

  def close(%__MODULE__{} = transport) do
    send(transport.owner, {:transport_closed, transport.id})
    %{transport | connected?: false, closed?: true}
  end

  def connected?(%__MODULE__{} = transport), do: transport.connected?
end
