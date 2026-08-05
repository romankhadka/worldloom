defmodule Worldloom.Repo.Migrations.AddSourceSequenceIndexToLoomEvents do
  use Ecto.Migration

  def change do
    create index(:loom_events, [:source, :id], name: :loom_events_source_id_index)
  end
end
