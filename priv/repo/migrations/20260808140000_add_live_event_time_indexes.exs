defmodule Worldloom.Repo.Migrations.AddLiveEventTimeIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_time_index :loom_events_source_occurred_at_id_index
  @primary_time_index :loom_events_primary_occurred_at_id_index

  def up do
    drop_if_exists index(:loom_events, [:source, :occurred_at, :id],
                     name: @source_time_index,
                     concurrently: true
                   )

    create index(:loom_events, [:source, :occurred_at, :id],
             name: @source_time_index,
             concurrently: true
           )

    drop_if_exists index(:loom_events, [:occurred_at, :id],
                     name: @primary_time_index,
                     concurrently: true
                   )

    create index(:loom_events, [:occurred_at, :id],
             name: @primary_time_index,
             where: "source <> 'open_meteo'",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:loom_events, [:occurred_at, :id],
                     name: @primary_time_index,
                     concurrently: true
                   )

    drop_if_exists index(:loom_events, [:source, :occurred_at, :id],
                     name: @source_time_index,
                     concurrently: true
                   )
  end
end
