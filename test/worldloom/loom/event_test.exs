defmodule Worldloom.Loom.EventTest do
  use Worldloom.DataCase, async: false

  alias Worldloom.Loom.Event

  @migration_version 20_260_808_180_000
  @migration_module Worldloom.Repo.Migrations.ExpandLoomSignalContracts
  @canonical_constraint "loom_events_kind_source_pair"
  @expanded_staging_constraint "loom_events_kind_source_pair_expanded_staged"
  @original_staging_constraint "loom_events_kind_source_pair_original_staged"
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260808180000_expand_loom_signal_contracts.exs",
                    __DIR__
                  )

  @original_pairs [
    {"wikimedia", "wikimedia"},
    {"earthquake", "usgs"},
    {"weather", "open_meteo"},
    {"tug", "visitor"},
    {"knot", "visitor"},
    {"illuminate", "visitor"}
  ]

  @new_pairs [
    {"public_activity", "bluesky"},
    {"route_change", "ripe_ris"},
    {"slot", "solana"},
    {"randomness", "drand"}
  ]

  test "required fields are rejected before persistence" do
    changeset = Event.changeset(%Event{}, %{})

    refute changeset.valid?

    assert %{
             kind: ["can't be blank"],
             source: ["can't be blank"],
             occurred_at: ["can't be blank"],
             render_version: ["can't be blank"],
             render_seed: ["can't be blank"],
             lane: ["can't be blank"],
             intensity: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "lane and intensity are bounded" do
    low_lane = Event.changeset(%Event{}, valid_attributes(%{lane: -0.01}))
    high_intensity = Event.changeset(%Event{}, valid_attributes(%{intensity: 1.01}))

    refute low_lane.valid?
    refute high_intensity.valid?
    assert "must be greater than or equal to 0.0" in errors_on(low_lane).lane
    assert "must be less than or equal to 1.0" in errors_on(high_intensity).intensity
  end

  test "only visitor events may omit an external id" do
    visitor =
      Event.changeset(
        %Event{},
        valid_attributes(%{kind: "tug", source: "visitor", external_id: nil})
      )

    tracked_visitor =
      Event.changeset(
        %Event{},
        valid_attributes(%{kind: "knot", source: "visitor", external_id: "visitor-123"})
      )

    anonymous_wikimedia = Event.changeset(%Event{}, valid_attributes(%{external_id: nil}))

    assert visitor.valid?
    refute tracked_visitor.valid?
    refute anonymous_wikimedia.valid?
    assert "must be blank for visitor events" in errors_on(tracked_visitor).external_id
    assert "can't be blank" in errors_on(anonymous_wikimedia).external_id
  end

  test "kind must belong to its source" do
    changeset =
      Event.changeset(
        %Event{},
        valid_attributes(%{kind: "earthquake", source: "wikimedia"})
      )

    refute changeset.valid?
    assert "does not match source" in errors_on(changeset).kind
  end

  test "upstream external ids are unique per source" do
    attributes = valid_attributes(%{external_id: "revision-42"})

    assert {:ok, _event} = %Event{} |> Event.changeset(attributes) |> Repo.insert()
    assert {:error, duplicate} = %Event{} |> Event.changeset(attributes) |> Repo.insert()
    assert "has already been taken" in errors_on(duplicate).external_id
  end

  test "multiple anonymous visitor events are allowed" do
    first = valid_attributes(%{kind: "tug", source: "visitor", external_id: nil})

    second =
      valid_attributes(%{kind: "knot", source: "visitor", external_id: nil, render_seed: 43})

    assert {:ok, _event} = %Event{} |> Event.changeset(first) |> Repo.insert()
    assert {:ok, _event} = %Event{} |> Event.changeset(second) |> Repo.insert()
  end

  test "database accepts exactly the ten approved kind and source pairs" do
    rows =
      (@original_pairs ++ @new_pairs)
      |> Enum.with_index()
      |> Enum.map(fn {{kind, source}, index} -> raw_attributes(kind, source, index) end)

    assert {10, inserted_pairs} =
             Repo.insert_all(Event, rows, returning: [:kind, :source])

    assert MapSet.new(inserted_pairs, &{&1.kind, &1.source}) ==
             MapSet.new(@original_pairs ++ @new_pairs)
  end

  test "database rejects a kind paired with the wrong approved source" do
    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Repo.insert_all(Event, [raw_attributes("slot", "bluesky", 100)])
      end)
    end
  end

  test "expanding the constraint leaves an existing version one row byte-for-byte unchanged" do
    load_migration!()
    run_migration(:down)

    assert {:ok, wikimedia} =
             %Event{}
             |> Event.changeset(valid_attributes(%{external_id: "v1-migration-sentinel"}))
             |> Repo.insert()

    row_before = serialized_row(wikimedia.id)

    run_migration(:up)

    assert serialized_row(wikimedia.id) == row_before
    refute File.read!(@migration_path) =~ ~r/\bUPDATE\b/i
  end

  test "migration stages table scans outside short write-blocking transactions" do
    load_migration!()
    migration_source = File.read!(@migration_path)

    migration_configuration = apply(@migration_module, :__migration__, [])

    assert migration_configuration[:disable_ddl_transaction]
    assert migration_source =~ "NOT VALID"
    assert migration_source =~ "VALIDATE CONSTRAINT"
    assert migration_source =~ "LOCK TABLE"
    assert migration_source =~ "IN SHARE ROW EXCLUSIVE MODE"

    [_, up_source, down_source] =
      Regex.run(
        ~r/  def up do\n(.*?)\n  end\n\n  def down do\n(.*?)\n  end/s,
        migration_source
      )

    assert operation_order(up_source) == [
             "prepare_expanded_constraint",
             "validate_expanded_constraint",
             "install_expanded_constraint"
           ]

    assert operation_order(down_source) == [
             "prepare_original_constraint",
             "validate_original_constraint",
             "install_original_constraint"
           ]
  end

  test "rerunning up recovers a validated staging constraint and a completed swap" do
    load_migration!()

    Repo.query!("""
    ALTER TABLE loom_events
    ADD CONSTRAINT #{@expanded_staging_constraint} CHECK (true) NOT VALID
    """)

    Repo.query!("""
    ALTER TABLE loom_events
    VALIDATE CONSTRAINT #{@expanded_staging_constraint}
    """)

    assert %{validated: true} = constraint_state(@expanded_staging_constraint)

    run_migration(:up)

    assert_expanded_canonical_constraint()
    assert constraint_state(@expanded_staging_constraint) == nil

    run_migration(:up)

    assert_expanded_canonical_constraint()
    assert constraint_state(@expanded_staging_constraint) == nil
  end

  test "rollback restores the original constraint when no new source rows exist" do
    load_migration!()

    Repo.query!("""
    ALTER TABLE loom_events
    ADD CONSTRAINT #{@original_staging_constraint} CHECK (true) NOT VALID
    """)

    Repo.query!("""
    ALTER TABLE loom_events
    VALIDATE CONSTRAINT #{@original_staging_constraint}
    """)

    run_migration(:down)

    assert_original_canonical_constraint()
    assert constraint_state(@original_staging_constraint) == nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn ->
        Repo.insert_all(Event, [raw_attributes("public_activity", "bluesky", 101)])
      end)
    end

    run_migration(:up)

    assert_expanded_canonical_constraint()

    assert {1, _rows} =
             Repo.insert_all(Event, [raw_attributes("public_activity", "bluesky", 102)])
  end

  test "rollback refuses clearly when a new source row exists" do
    load_migration!()

    assert {1, _rows} =
             Repo.insert_all(Event, [raw_attributes("randomness", "drand", 103)])

    assert_raise RuntimeError, ~r/cannot roll back.*new signal source rows exist/i, fn ->
      run_migration(:down)
    end

    assert_expanded_canonical_constraint()
    assert constraint_state(@original_staging_constraint) == nil
  end

  defp valid_attributes(overrides) do
    Map.merge(
      %{
        kind: "wikimedia",
        source: "wikimedia",
        external_id: "revision-41",
        occurred_at: ~U[2026-08-03 12:00:00.000000Z],
        render_version: 1,
        render_seed: 42,
        lane: 0.5,
        intensity: 0.7,
        payload: %{"summary" => "An encyclopedia page changed"}
      },
      overrides
    )
  end

  defp raw_attributes(kind, source, index) do
    occurred_at = DateTime.add(~U[2026-08-03 12:00:00.000000Z], index, :second)

    %{
      kind: kind,
      source: source,
      external_id: if(source == "visitor", do: nil, else: "#{source}-#{index}"),
      occurred_at: occurred_at,
      render_version: if(source in ~w(bluesky ripe_ris solana drand), do: 2, else: 1),
      render_seed: index + 1,
      lane: 0.5,
      intensity: 0.7,
      payload: %{"summary" => "Database constraint test"},
      inserted_at: occurred_at
    }
  end

  defp load_migration! do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end
  end

  defp run_migration(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      @migration_module,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp serialized_row(id) do
    assert %{rows: [[serialized]]} =
             Repo.query!(
               "SELECT row_to_json(loom_events)::text FROM loom_events WHERE id = $1",
               [id]
             )

    serialized
  end

  defp operation_order(function_source) do
    Regex.scan(
      ~r/execute\(&([a-z_]+)\/0\)/,
      function_source,
      capture: :all_but_first
    )
    |> List.flatten()
  end

  defp assert_expanded_canonical_constraint do
    assert %{definition: definition, validated: true} =
             constraint_state(@canonical_constraint)

    for source <- ~w(wikimedia usgs open_meteo visitor bluesky ripe_ris solana drand) do
      assert definition =~ source
    end
  end

  defp assert_original_canonical_constraint do
    assert %{definition: definition, validated: true} =
             constraint_state(@canonical_constraint)

    for source <- ~w(wikimedia usgs open_meteo visitor) do
      assert definition =~ source
    end

    for source <- ~w(bluesky ripe_ris solana drand) do
      refute definition =~ source
    end
  end

  defp constraint_state(name) do
    case Repo.query!(
           """
           SELECT pg_get_constraintdef(oid, true), convalidated
           FROM pg_constraint
           WHERE conrelid = 'loom_events'::regclass AND conname = $1
           """,
           [name]
         ).rows do
      [[definition, validated]] -> %{definition: definition, validated: validated}
      [] -> nil
    end
  end
end
