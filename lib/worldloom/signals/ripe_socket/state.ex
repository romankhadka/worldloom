defmodule Worldloom.Signals.RipeSocket.State do
  @derive {Inspect,
           except: [
             :url,
             :transport,
             :transport_options,
             :collectors,
             :pending_acknowledgements
           ]}
  defstruct [
    :url,
    :collectors,
    :transport,
    :transport_module,
    :transport_options,
    :window,
    :buffer,
    :health_registry,
    :clock,
    :random,
    :timer,
    :upgrade_generation,
    :subscription_generation,
    :reconnect_token,
    pending_acknowledgements: MapSet.new(),
    awaiting_acknowledgements?: false,
    subscribed?: false,
    attempt: 0
  ]
end
