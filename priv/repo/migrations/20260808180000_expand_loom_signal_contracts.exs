defmodule Worldloom.Repo.Migrations.ExpandLoomSignalContracts do
  use Ecto.Migration

  @constraint_name :loom_events_kind_source_pair
  @original_pairs """
  (source = 'wikimedia' AND kind = 'wikimedia') OR
  (source = 'usgs' AND kind = 'earthquake') OR
  (source = 'open_meteo' AND kind = 'weather') OR
  (source = 'visitor' AND kind IN ('tug', 'knot', 'illuminate'))
  """
  @expanded_pairs @original_pairs <>
                    """
                    OR (source = 'bluesky' AND kind = 'public_activity')
                    OR (source = 'ripe_ris' AND kind = 'route_change')
                    OR (source = 'solana' AND kind = 'slot')
                    OR (source = 'drand' AND kind = 'randomness')
                    """
  @new_sources ~w(bluesky ripe_ris solana drand)

  def up do
    drop constraint(:loom_events, @constraint_name)
    create constraint(:loom_events, @constraint_name, check: @expanded_pairs)
  end

  def down do
    execute(&ensure_no_new_source_rows!/0)
    drop constraint(:loom_events, @constraint_name)
    create constraint(:loom_events, @constraint_name, check: @original_pairs)
  end

  defp ensure_no_new_source_rows! do
    query = """
    SELECT source
    FROM #{qualified_loom_events()}
    WHERE source = ANY($1::text[])
    LIMIT 1
    """

    case repo().query!(query, [@new_sources]).rows do
      [] ->
        :ok

      [[source]] ->
        raise "cannot roll back expanded loom signal contracts: " <>
                "new signal source rows exist (found #{source})"
    end
  end

  defp qualified_loom_events do
    case prefix() do
      nil -> ~s("loom_events")
      migration_prefix -> ~s(#{quote_identifier(migration_prefix)}."loom_events")
    end
  end

  defp quote_identifier(identifier) do
    escaped_identifier = String.replace(identifier, ~s("), ~s(""))
    ~s("#{escaped_identifier}")
  end
end
