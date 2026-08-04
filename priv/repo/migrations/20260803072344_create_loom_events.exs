defmodule Worldloom.Repo.Migrations.CreateLoomEvents do
  use Ecto.Migration

  def change do
    create table(:loom_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :kind, :string, null: false
      add :source, :string, null: false
      add :external_id, :string
      add :occurred_at, :utc_datetime_usec, null: false
      add :render_version, :integer, null: false
      add :render_seed, :bigint, null: false
      add :lane, :float, null: false
      add :intensity, :float, null: false
      add :payload, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:loom_events, :loom_events_lane_bounds,
             check: "lane >= 0.0 AND lane <= 1.0"
           )

    create constraint(:loom_events, :loom_events_intensity_bounds,
             check: "intensity >= 0.0 AND intensity <= 1.0"
           )

    create constraint(:loom_events, :loom_events_kind_source_pair,
             check:
               "(source = 'wikimedia' AND kind = 'wikimedia') OR " <>
                 "(source = 'usgs' AND kind = 'earthquake') OR " <>
                 "(source = 'open_meteo' AND kind = 'weather') OR " <>
                 "(source = 'visitor' AND kind IN ('tug', 'knot', 'illuminate'))"
           )

    create constraint(:loom_events, :loom_events_render_contract,
             check: "render_version > 0 AND render_seed >= 0 AND render_seed < 2147483647"
           )

    create constraint(:loom_events, :loom_events_external_identity,
             check:
               "(source = 'visitor' AND external_id IS NULL) OR " <>
                 "(source <> 'visitor' AND external_id IS NOT NULL)"
           )

    create constraint(:loom_events, :loom_events_payload_size,
             check:
               "octet_length(payload::text) <= 16384 AND " <>
                 "char_length(COALESCE(payload->>'summary', '')) <= 160"
           )

    create unique_index(:loom_events, [:source, :external_id],
             where: "external_id IS NOT NULL",
             name: :loom_events_source_external_id_index
           )

    create index(:loom_events, [:occurred_at, :id])
  end
end
