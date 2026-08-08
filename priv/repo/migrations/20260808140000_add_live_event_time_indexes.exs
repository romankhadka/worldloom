defmodule Worldloom.Repo.Migrations.AddLiveEventTimeIndexes do
  use Ecto.Migration

  @source_time_index :loom_events_source_occurred_at_id_index
  @primary_time_index :loom_events_primary_occurred_at_id_index

  def up do
    create index(:loom_events, [:source, :occurred_at, :id], name: @source_time_index)

    create index(:loom_events, [:occurred_at, :id],
             name: @primary_time_index,
             where: "source <> 'open_meteo'"
           )
  end

  def down do
    drop index(:loom_events, [:occurred_at, :id], name: @primary_time_index)
    drop index(:loom_events, [:source, :occurred_at, :id], name: @source_time_index)
  end
end
