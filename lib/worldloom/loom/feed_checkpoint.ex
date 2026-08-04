defmodule Worldloom.Loom.FeedCheckpoint do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:source, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @sources ~w(wikimedia usgs open_meteo)

  @type t :: %__MODULE__{}

  schema "feed_checkpoints" do
    field :cursor, :string
    field :etag, :string
    field :last_successful_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(checkpoint, attributes) do
    checkpoint
    |> cast(attributes, [:source, :cursor, :etag, :last_successful_at, :metadata])
    |> validate_required([:source, :last_successful_at, :metadata])
    |> validate_inclusion(:source, @sources)
    |> validate_length(:cursor, max: 8_192)
    |> validate_length(:etag, max: 512)
    |> validate_metadata_size()
    |> check_constraint(:cursor, name: :feed_checkpoints_cursor_size)
    |> check_constraint(:etag, name: :feed_checkpoints_etag_size)
    |> check_constraint(:metadata, name: :feed_checkpoints_metadata_size)
    |> unique_constraint(:source, name: :feed_checkpoints_pkey)
  end

  defp validate_metadata_size(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      if byte_size(Jason.encode!(metadata)) > 8_192 do
        [metadata: "must encode to at most 8192 bytes"]
      else
        []
      end
    end)
  end
end
