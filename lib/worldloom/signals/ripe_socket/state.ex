defmodule Worldloom.Signals.RipeSocket.State do
  @derive {Inspect,
           except: [
             :url,
             :transport,
             :transport_options,
             :collectors
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
    :reconnect_token,
    subscribed?: false,
    attempt: 0
  ]
end
