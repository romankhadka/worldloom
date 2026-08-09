defmodule Worldloom.Signals.SolanaSocket.State do
  @derive {Inspect,
           except: [
             :url,
             :transport,
             :transport_options,
             :subscription_id,
             :committed_slot
           ]}
  defstruct [
    :url,
    :transport,
    :transport_module,
    :transport_options,
    :window,
    :subscription_id,
    :committed_slot,
    :buffer,
    :health_registry,
    :clock,
    :random,
    :timer,
    :upgrade_generation,
    :reconnect_token,
    subscribed?: false,
    attempt: 0
  ]
end
