defmodule Worldloom.Loom.FeedCheckpointTest do
  use Worldloom.DataCase, async: true

  alias Worldloom.Loom.FeedCheckpoint

  test "source and last successful at are required" do
    changeset = FeedCheckpoint.changeset(%FeedCheckpoint{}, %{})

    refute changeset.valid?

    assert %{
             source: ["can't be blank"],
             last_successful_at: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "accepts the seven external feed sources and rejects visitors" do
    for source <- ~w(wikimedia usgs open_meteo bluesky ripe_ris solana drand) do
      assert FeedCheckpoint.changeset(
               %FeedCheckpoint{},
               valid_attributes(%{source: source})
             ).valid?
    end

    visitor =
      FeedCheckpoint.changeset(
        %FeedCheckpoint{},
        valid_attributes(%{source: "visitor"})
      )

    refute visitor.valid?
    assert "is invalid" in errors_on(visitor).source
  end

  test "cursor and etag have hard length limits" do
    oversized_cursor =
      FeedCheckpoint.changeset(
        %FeedCheckpoint{},
        valid_attributes(%{cursor: String.duplicate("c", 8193)})
      )

    oversized_etag =
      FeedCheckpoint.changeset(
        %FeedCheckpoint{},
        valid_attributes(%{etag: String.duplicate("e", 513)})
      )

    refute oversized_cursor.valid?
    refute oversized_etag.valid?
    assert "should be at most 8192 character(s)" in errors_on(oversized_cursor).cursor
    assert "should be at most 512 character(s)" in errors_on(oversized_etag).etag
  end

  test "metadata is limited to eight kilobytes" do
    changeset =
      FeedCheckpoint.changeset(
        %FeedCheckpoint{},
        valid_attributes(%{metadata: %{"detail" => String.duplicate("x", 8192)}})
      )

    refute changeset.valid?
    assert "must encode to at most 8192 bytes" in errors_on(changeset).metadata
  end

  test "a valid checkpoint is persisted with microsecond timestamps" do
    assert {:ok, checkpoint} =
             %FeedCheckpoint{}
             |> FeedCheckpoint.changeset(valid_attributes())
             |> Repo.insert()

    assert checkpoint.source == "wikimedia"
    assert checkpoint.metadata == %{}
    assert checkpoint.last_successful_at.microsecond == {123_456, 6}
    assert {_, 6} = checkpoint.inserted_at.microsecond
    assert {_, 6} = checkpoint.updated_at.microsecond
  end

  defp valid_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        source: "wikimedia",
        cursor: "cursor-41",
        etag: ~s("etag-41"),
        last_successful_at: ~U[2026-08-03 12:00:00.123456Z],
        metadata: %{}
      },
      overrides
    )
  end
end
