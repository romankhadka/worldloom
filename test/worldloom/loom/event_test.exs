defmodule Worldloom.Loom.EventTest do
  use Worldloom.DataCase, async: true

  alias Worldloom.Loom.Event

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
end
