defmodule Worldloom.Repo.Migrations.ExpandLoomSignalContracts do
  use Ecto.Migration

  @disable_ddl_transaction true

  @canonical_constraint "loom_events_kind_source_pair"
  @expanded_staging_constraint "loom_events_kind_source_pair_expanded_staged"
  @original_staging_constraint "loom_events_kind_source_pair_original_staged"
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
    execute(&prepare_expanded_constraint/0)
    execute(&validate_expanded_constraint/0)
    execute(&install_expanded_constraint/0)
  end

  def down do
    execute(&prepare_original_constraint/0)
    execute(&validate_original_constraint/0)
    execute(&install_original_constraint/0)
  end

  defp prepare_expanded_constraint do
    in_short_transaction(fn ->
      drop_constraint_if_present(@expanded_staging_constraint)
      add_unvalidated_constraint(@expanded_staging_constraint, @expanded_pairs)
    end)
  end

  defp validate_expanded_constraint do
    validate_constraint(@expanded_staging_constraint)
  end

  defp install_expanded_constraint do
    replace_canonical_constraint(@expanded_staging_constraint)
  end

  defp prepare_original_constraint do
    in_short_transaction(fn ->
      execute_sql("LOCK TABLE #{qualified_loom_events()} IN SHARE ROW EXCLUSIVE MODE")
      ensure_no_new_source_rows!()
      drop_constraint_if_present(@original_staging_constraint)
      add_unvalidated_constraint(@original_staging_constraint, @original_pairs)
    end)
  end

  defp validate_original_constraint do
    validate_constraint(@original_staging_constraint)
  end

  defp install_original_constraint do
    replace_canonical_constraint(@original_staging_constraint)
  end

  defp add_unvalidated_constraint(name, check_expression) do
    execute_sql("""
    ALTER TABLE #{qualified_loom_events()}
    ADD CONSTRAINT #{quote_identifier(name)} CHECK (#{check_expression}) NOT VALID
    """)
  end

  defp validate_constraint(name) do
    execute_sql("""
    ALTER TABLE #{qualified_loom_events()}
    VALIDATE CONSTRAINT #{quote_identifier(name)}
    """)
  end

  defp replace_canonical_constraint(staging_constraint) do
    in_short_transaction(fn ->
      execute_sql("LOCK TABLE #{qualified_loom_events()} IN ACCESS EXCLUSIVE MODE")
      drop_constraint(@canonical_constraint)

      execute_sql("""
      ALTER TABLE #{qualified_loom_events()}
      RENAME CONSTRAINT #{quote_identifier(staging_constraint)}
      TO #{quote_identifier(@canonical_constraint)}
      """)
    end)
  end

  defp ensure_no_new_source_rows! do
    query = """
    SELECT source
    FROM #{qualified_loom_events()}
    WHERE source = ANY($1::text[])
    LIMIT 1
    """

    case repo().query!(query, [@new_sources], timeout: :infinity).rows do
      [] ->
        :ok

      [[source]] ->
        raise "cannot roll back expanded loom signal contracts: " <>
                "new signal source rows exist (found #{source})"
    end
  end

  defp drop_constraint(name) do
    execute_sql("""
    ALTER TABLE #{qualified_loom_events()}
    DROP CONSTRAINT #{quote_identifier(name)}
    """)
  end

  defp drop_constraint_if_present(name) do
    execute_sql("""
    ALTER TABLE #{qualified_loom_events()}
    DROP CONSTRAINT IF EXISTS #{quote_identifier(name)}
    """)
  end

  defp in_short_transaction(operation) do
    {:ok, :ok} =
      repo().transaction(
        fn ->
          operation.()
          :ok
        end,
        timeout: :infinity
      )

    :ok
  end

  defp execute_sql(statement) do
    repo().query!(statement, [], timeout: :infinity)
    :ok
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
