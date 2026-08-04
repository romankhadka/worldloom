defmodule Worldloom.Loom.GesturePolicy do
  alias Worldloom.Loom.Coordinator
  alias Worldloom.Loom.RateLimiter
  alias Worldloom.Loom.SourceEvent

  @gestures %{
    "tug" => {:tug, 0.45, "A visitor tugged the living edge"},
    "knot" => {:knot, 0.65, "A visitor tied a knot in the weave"},
    "illuminate" => {:illuminate, 0.8, "A visitor illuminated a thread"}
  }

  @spec authorize(map(), keyword()) ::
          {:ok, SourceEvent.t(), String.t()}
          | {:error, atom(), non_neg_integer() | nil}
  def authorize(payload, context) when is_map(payload) and is_list(context) do
    with {:ok, kind, intensity, summary, lane} <- validate_payload(payload),
         :ok <- validate_live_edge(context[:live_edge?]),
         {:ok, identity} <- validate_identity(context[:identity]),
         {:ok, peer_address} <- validate_peer_address(context[:peer_address]),
         {:ok, occurred_at} <- current_time(context),
         {:ok, event} <- visitor_event(kind, intensity, summary, lane, occurred_at),
         :ok <- authorize_rate(identity, peer_address, occurred_at, context),
         {:ok, request_nonce} <- request_nonce(context) do
      {:ok, event, request_nonce}
    end
  end

  def authorize(_payload, _context), do: {:error, :invalid, nil}

  @spec commit(map(), keyword()) ::
          {:ok, term()} | {:error, atom(), non_neg_integer() | nil}
  def commit(payload, context) do
    with {:ok, event, request_nonce} <- authorize(payload, context) do
      committer = Keyword.get(context, :committer, default_committer(context))

      case committer.(event, request_nonce) do
        {:ok, committed_event} -> {:ok, committed_event}
        {:error, _private_reason} -> {:error, :unavailable, nil}
      end
    end
  end

  defp validate_payload(%{"gesture" => gesture, "lane" => lane}) do
    with {kind, intensity, summary} <- Map.get(@gestures, gesture),
         {:ok, normalized_lane} <- normalize_lane(lane) do
      {:ok, kind, intensity, summary, normalized_lane}
    else
      _invalid -> {:error, :invalid, nil}
    end
  end

  defp validate_payload(_payload), do: {:error, :invalid, nil}

  defp normalize_lane(lane) when is_integer(lane) and lane in 0..1, do: {:ok, lane * 1.0}

  defp normalize_lane(lane) when is_float(lane) and lane >= 0.0 and lane <= 1.0,
    do: {:ok, lane}

  defp normalize_lane(_lane), do: {:error, :invalid, nil}

  defp validate_live_edge(true), do: :ok
  defp validate_live_edge(_not_live), do: {:error, :not_live, nil}

  defp validate_identity(identity) when is_binary(identity) do
    case Base.url_decode64(identity, padding: false) do
      {:ok, decoded_identity} when byte_size(decoded_identity) == 32 -> {:ok, identity}
      _invalid -> {:error, :invalid_identity, nil}
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_identity, nil}

  defp validate_peer_address(peer_address)
       when is_tuple(peer_address) and tuple_size(peer_address) in [4, 8] do
    maximum_part = if tuple_size(peer_address) == 4, do: 255, else: 65_535

    if peer_address
       |> Tuple.to_list()
       |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= maximum_part)) do
      {:ok, peer_address}
    else
      {:error, :invalid_peer, nil}
    end
  end

  defp validate_peer_address(_peer_address), do: {:error, :invalid_peer, nil}

  defp current_time(context) do
    case Keyword.get(context, :clock, &DateTime.utc_now/0).() do
      %DateTime{} = occurred_at -> {:ok, occurred_at}
      _invalid_time -> {:error, :invalid, nil}
    end
  end

  defp visitor_event(kind, intensity, summary, lane, occurred_at) do
    SourceEvent.new(%{
      kind: kind,
      source: :visitor,
      external_id: nil,
      occurred_at: occurred_at,
      lane: lane,
      intensity: intensity,
      payload: %{"summary" => summary}
    })
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, _reason} -> {:error, :invalid, nil}
    end
  end

  defp authorize_rate(identity, peer_address, occurred_at, context) do
    rate_limiter = Keyword.get(context, :rate_limiter, default_rate_limiter(context))
    rate_limiter.(identity, peer_address, DateTime.to_unix(occurred_at, :millisecond))
  end

  defp request_nonce(context) do
    nonce = Keyword.get(context, :nonce, &new_nonce/0).()

    if is_binary(nonce) and nonce != "" do
      {:ok, nonce}
    else
      {:error, :invalid, nil}
    end
  end

  defp default_rate_limiter(context) do
    server = Keyword.get(context, :rate_limiter_server, RateLimiter)

    fn identity, peer_address, now_ms ->
      RateLimiter.authorize(server, identity, peer_address, now_ms)
    end
  end

  defp default_committer(context) do
    coordinator = Keyword.get(context, :coordinator, Coordinator)
    fn event, request_nonce -> Coordinator.commit_visitor(coordinator, event, request_nonce) end
  end

  defp new_nonce do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
