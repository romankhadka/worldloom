defmodule Worldloom.Loom.TimelineWindow do
  alias Worldloom.Loom.Event

  @enforce_keys [:start_at, :end_at, :duration_seconds, :events, :ambient, :archive_start_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          start_at: DateTime.t(),
          end_at: DateTime.t(),
          duration_seconds: 60 | 300 | 900,
          events: [Event.t()],
          ambient: Event.t() | nil,
          archive_start_at: DateTime.t() | nil
        }
end
