defmodule WorldloomWeb.E2EController do
  use WorldloomWeb, :controller

  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.SourceEvent

  def late(conn, _params) do
    snapshot = Coordinator.current_snapshot()

    case snapshot.window_end do
      nil ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "live window unavailable"})

      window_end ->
        event = late_event(window_end, snapshot.commit_watermark)

        case Coordinator.commit_external([event], nil) do
          {:ok, [stored_event]} ->
            json(conn, %{
              occurred_at: DateTime.to_iso8601(stored_event.occurred_at),
              sequence: stored_event.id
            })

          {:ok, []} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "late event already committed"})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end
    end
  end

  defp late_event(window_end, commit_watermark) do
    SourceEvent.new!(%{
      kind: :wikimedia,
      source: :wikimedia,
      external_id: "worldloom-e2e-late-#{commit_watermark + 1}",
      occurred_at: DateTime.add(window_end, -120, :second),
      lane: 0.42,
      intensity: 0.56,
      payload: %{
        "summary" => "A deterministic late edit reached the loom",
        "window_count" => 1,
        "window_span_seconds" => 4,
        "count" => 1,
        "total_absolute_byte_delta" => 137,
        "language_buckets" => %{
          "current_1" => 1,
          "current_2" => 0,
          "current_3" => 0,
          "current_4" => 0,
          "current_5" => 0
        },
        "edit_types" => %{
          "categorize" => 0,
          "edit" => 1,
          "external" => 0,
          "log" => 0,
          "new" => 0
        },
        "dominant_edit_type" => "edit",
        "truncated" => false
      }
    })
  end
end
