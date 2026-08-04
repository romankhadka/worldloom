defmodule Worldloom.Repo.Migrations.CreateFeedCheckpoints do
  use Ecto.Migration

  def change do
    create table(:feed_checkpoints, primary_key: false) do
      add :source, :string, primary_key: true
      add :cursor, :text
      add :etag, :text
      add :last_successful_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:feed_checkpoints, :feed_checkpoints_cursor_size,
             check: "octet_length(COALESCE(cursor, '')) <= 8192"
           )

    create constraint(:feed_checkpoints, :feed_checkpoints_etag_size,
             check: "octet_length(COALESCE(etag, '')) <= 512"
           )

    create constraint(:feed_checkpoints, :feed_checkpoints_metadata_size,
             check: "octet_length(metadata::text) <= 8192"
           )
  end
end
