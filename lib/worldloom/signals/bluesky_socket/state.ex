defmodule Worldloom.Signals.BlueskySocket.State do
  @derive {Inspect,
           except: [
             :url,
             :transport,
             :transport_options,
             :recovery,
             :committed_cursor,
             :window_cursor,
             :next_window,
             :next_window_cursor,
             :next_recovery
           ]}
  defstruct [
    :url,
    :transport,
    :transport_module,
    :transport_options,
    :window,
    :window_cursor,
    :next_window,
    :next_window_cursor,
    :next_recovery,
    :recovery,
    :committed_cursor,
    :buffer,
    :health_registry,
    :clock,
    :random,
    :timer,
    :upgrade_generation,
    :reconnect_token,
    attempt: 0
  ]
end
