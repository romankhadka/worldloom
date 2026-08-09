defmodule Worldloom.Signals.DrandWorker.State do
  @derive {Inspect,
           except: [
             :client,
             :client_options,
             :buffer,
             :health_registry,
             :clock,
             :random,
             :timer
           ]}
  defstruct [
    :client,
    :client_module,
    :client_options,
    :schedule,
    :committed_round,
    :buffer,
    :health_registry,
    :clock,
    :random,
    :timer,
    :timer_token,
    :timer_kind,
    attempt: 0
  ]
end
