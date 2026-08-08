defmodule Worldloom.Loom.LiveSnapshot do
  @enforce_keys [:window_end, :commit_watermark, :display_events, :memory_events, :ambient]
  defstruct snapshot_version: 1,
            window_end: nil,
            commit_watermark: 0,
            display_events: [],
            memory_events: [],
            ambient: nil

  @type t :: %__MODULE__{
          snapshot_version: 1,
          window_end: DateTime.t() | nil,
          commit_watermark: non_neg_integer(),
          display_events: [Worldloom.Loom.Event.t()],
          memory_events: [Worldloom.Loom.Event.t()],
          ambient: Worldloom.Loom.Event.t() | nil
        }
end
