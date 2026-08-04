defmodule Worldloom.Loom.Event do
  use Ecto.Schema

  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]
  @kinds ~w(wikimedia earthquake weather tug knot illuminate)
  @sources ~w(wikimedia usgs open_meteo visitor)
  @kind_by_source %{
    "wikimedia" => ["wikimedia"],
    "usgs" => ["earthquake"],
    "open_meteo" => ["weather"],
    "visitor" => ~w(tug knot illuminate)
  }

  @type t :: %__MODULE__{}

  schema "loom_events" do
    field :kind, :string
    field :source, :string
    field :external_id, :string
    field :occurred_at, :utc_datetime_usec
    field :render_version, :integer
    field :render_seed, :integer
    field :lane, :float
    field :intensity, :float
    field :payload, :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(event, attributes) do
    event
    |> cast(attributes, [
      :kind,
      :source,
      :external_id,
      :occurred_at,
      :render_version,
      :render_seed,
      :lane,
      :intensity,
      :payload
    ])
    |> validate_required([
      :kind,
      :source,
      :occurred_at,
      :render_version,
      :render_seed,
      :lane,
      :intensity,
      :payload
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:external_id, max: 255)
    |> validate_number(:render_version, greater_than: 0)
    |> validate_number(:render_seed, greater_than_or_equal_to: 0, less_than: 2_147_483_647)
    |> validate_number(:lane, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:intensity, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_kind_source_pair()
    |> validate_external_identity()
    |> validate_payload_size()
    |> check_constraint(:lane, name: :loom_events_lane_bounds)
    |> check_constraint(:intensity, name: :loom_events_intensity_bounds)
    |> check_constraint(:kind, name: :loom_events_kind_source_pair)
    |> check_constraint(:render_version, name: :loom_events_render_contract)
    |> check_constraint(:external_id, name: :loom_events_external_identity)
    |> check_constraint(:payload, name: :loom_events_payload_size)
    |> unique_constraint(:external_id, name: :loom_events_source_external_id_index)
  end

  defp validate_kind_source_pair(changeset) do
    source = get_field(changeset, :source)
    kind = get_field(changeset, :kind)

    if source in @sources and kind in @kinds and kind not in Map.fetch!(@kind_by_source, source) do
      add_error(changeset, :kind, "does not match source")
    else
      changeset
    end
  end

  defp validate_external_identity(changeset) do
    case {get_field(changeset, :source), get_field(changeset, :external_id)} do
      {"visitor", external_id} when is_binary(external_id) ->
        add_error(changeset, :external_id, "must be blank for visitor events")

      {source, nil} when source in ["wikimedia", "usgs", "open_meteo"] ->
        add_error(changeset, :external_id, "can't be blank")

      _other ->
        changeset
    end
  end

  defp validate_payload_size(changeset) do
    validate_change(changeset, :payload, fn :payload, payload ->
      encoded_payload = Jason.encode!(payload)
      summary = Map.get(payload, "summary", "")

      []
      |> maybe_add_payload_error(
        byte_size(encoded_payload) > 16_384,
        "must encode to at most 16384 bytes"
      )
      |> maybe_add_payload_error(
        is_binary(summary) and String.length(summary) > 160,
        "summary must be at most 160 characters"
      )
    end)
  end

  defp maybe_add_payload_error(errors, true, message), do: [{:payload, message} | errors]
  defp maybe_add_payload_error(errors, false, _message), do: errors
end
