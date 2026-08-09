defmodule Worldloom.Signals.RipeWindow do
  alias Worldloom.Signals.BoundedCounter

  @derive {Inspect,
           except: [
             :approved_collector_fingerprints,
             :observed_collector_fingerprints,
             :peer_fingerprints,
             :pending
           ]}
  @enforce_keys [:window_start, :approved_collector_fingerprints]
  defstruct window_start: nil,
            announced: 0,
            withdrawn: 0,
            ipv4: 0,
            ipv6: 0,
            approved_collector_fingerprints: MapSet.new(),
            observed_collector_fingerprints: MapSet.new(),
            peer_fingerprints: MapSet.new(),
            truncated: false,
            pending: nil

  @type t :: %__MODULE__{
          window_start: DateTime.t(),
          announced: non_neg_integer(),
          withdrawn: non_neg_integer(),
          ipv4: non_neg_integer(),
          ipv6: non_neg_integer(),
          approved_collector_fingerprints: MapSet.t(binary()),
          observed_collector_fingerprints: MapSet.t(binary()),
          peer_fingerprints: MapSet.t(binary()),
          truncated: boolean(),
          pending: t() | nil
        }

  @window_seconds 4
  @offset_seconds 2
  @lateness_seconds 1
  @past_bound_microseconds 20_000_000
  @future_bound_microseconds 5_000_000
  @uint32_max 4_294_967_295
  @max_unix_second 253_402_300_799
  @announcement_group_capacity 2_048
  @prefix_capacity 2_048
  @peer_capacity 2_048
  @collector_pattern ~r/\Arrc\d{2}\z/
  @peer_asn_pattern ~r/\A\d+\z/

  @spec request_rrc_list_message() :: map()
  def request_rrc_list_message do
    %{"type" => "request_rrc_list", "data" => nil}
  end

  @spec subscription_messages(term(), term()) :: {:ok, [map()]} | {:error, atom()}
  def subscription_messages(configured_collectors, response) do
    with :ok <- validate_configured_collectors(configured_collectors),
         {:ok, available_collectors} <- validate_rrc_list(response),
         approved_collectors =
           Enum.filter(configured_collectors, &MapSet.member?(available_collectors, &1)),
         false <- approved_collectors == [] do
      {:ok, Enum.map(approved_collectors, &subscription_message/1)}
    else
      {:error, _reason} = error -> error
      true -> {:error, :no_available_collectors}
    end
  end

  @spec new(DateTime.t(), [String.t()]) :: t()
  def new(%DateTime{} = observed_at, approved_collectors) do
    case validate_configured_collectors(approved_collectors) do
      :ok ->
        approved_collector_fingerprints =
          approved_collectors
          |> Enum.map(&fingerprint/1)
          |> MapSet.new()

        empty_window(observed_at, approved_collector_fingerprints)

      {:error, :invalid_collectors} ->
        raise ArgumentError, "approved collectors must be one to four unique rrcNN names"
    end
  end

  def new(_observed_at, _approved_collectors) do
    raise ArgumentError, "window time must be a DateTime"
  end

  @spec add(t(), map(), DateTime.t()) ::
          {:ok, t()} | {:close_required, t()} | {:drop, atom(), t()}
  def add(%__MODULE__{} = window, frame, %DateTime{} = receipt_at) when is_map(frame) do
    with {:ok, observation} <- sanitize(frame, window, receipt_at),
         {:ok, delta} <- traverse_update(observation.announcements, observation.withdrawals) do
      route_observation(window, observation, delta, receipt_at)
    else
      {:error, reason} -> {:drop, reason, window}
    end
  end

  def add(%__MODULE__{} = window, _frame, %DateTime{}),
    do: {:drop, :invalid_frame, window}

  def add(%__MODULE__{}, _frame, _receipt_at),
    do: raise(ArgumentError, "receipt time must be a DateTime")

  @spec elapsed?(t(), DateTime.t()) :: boolean()
  def elapsed?(%__MODULE__{} = window, %DateTime{} = observed_at) do
    with {:ok, utc_observed_at} <- DateTime.shift_zone(observed_at, "Etc/UTC") do
      close_at =
        DateTime.add(
          window.window_start,
          @window_seconds + @lateness_seconds,
          :second
        )

      DateTime.compare(utc_observed_at, close_at) in [:eq, :gt]
    else
      {:error, _reason} -> false
    end
  end

  def elapsed?(%__MODULE__{}, _observed_at), do: false

  @spec close(t(), DateTime.t()) :: {:open, t()} | {:flush, map() | :empty, t()}
  def close(%__MODULE__{} = window, %DateTime{} = observed_at) do
    if elapsed?(window, observed_at) do
      {:flush, flush(window), next_window(window, observed_at)}
    else
      {:open, window}
    end
  end

  def close(%__MODULE__{} = window, _observed_at), do: {:open, window}

  @spec flush(t()) :: map() | :empty
  def flush(%__MODULE__{announced: 0, withdrawn: 0}), do: :empty

  def flush(%__MODULE__{} = window) do
    %{
      window_start: window.window_start,
      announced: window.announced,
      withdrawn: window.withdrawn,
      ipv4: window.ipv4,
      ipv6: window.ipv6,
      collector_count: MapSet.size(window.observed_collector_fingerprints),
      peer_count: MapSet.size(window.peer_fingerprints),
      truncated: window.truncated
    }
  end

  defp subscription_message(collector) do
    %{
      "type" => "ris_subscribe",
      "data" => %{
        "type" => "UPDATE",
        "host" => collector,
        "socketOptions" => %{"includeRaw" => false, "acknowledge" => true}
      }
    }
  end

  defp validate_configured_collectors(collectors) when is_list(collectors) do
    case reduce_collector_list(collectors, 4) do
      {:ok, collector_set} ->
        if MapSet.size(collector_set) > 0, do: :ok, else: {:error, :invalid_collectors}

      :invalid ->
        {:error, :invalid_collectors}
    end
  end

  defp validate_configured_collectors(_collectors), do: {:error, :invalid_collectors}

  defp validate_rrc_list(%{"type" => "ris_rrc_list", "data" => collectors})
       when is_list(collectors) do
    case reduce_collector_list(collectors, 100) do
      {:ok, available_collectors} -> {:ok, available_collectors}
      :invalid -> {:error, :invalid_rrc_list}
    end
  end

  defp validate_rrc_list(_response), do: {:error, :invalid_rrc_list}

  defp reduce_collector_list(collectors, capacity) do
    case Enum.reduce_while(collector_entries(collectors), {MapSet.new(), 0}, fn
           :improper_tail, _state ->
             {:halt, :invalid}

           {:collector, collector}, {seen, count} ->
             cond do
               count == capacity ->
                 {:halt, :invalid}

               not valid_collector?(collector) ->
                 {:halt, :invalid}

               MapSet.member?(seen, collector) ->
                 {:halt, :invalid}

               true ->
                 {:cont, {MapSet.put(seen, collector), count + 1}}
             end
         end) do
      {collector_set, _count} -> {:ok, collector_set}
      :invalid -> :invalid
    end
  end

  defp collector_entries(collectors) do
    Stream.unfold(collectors, fn
      [] -> nil
      [collector | remaining] -> {{:collector, collector}, remaining}
      _improper_tail -> {:improper_tail, []}
    end)
  end

  defp valid_collector?(collector) when is_binary(collector),
    do: byte_size(collector) == 5 and Regex.match?(@collector_pattern, collector)

  defp valid_collector?(_collector), do: false

  defp empty_window(observed_at, approved_collector_fingerprints) do
    window_start = BoundedCounter.window_start(observed_at, @window_seconds, @offset_seconds)
    empty_window_at(window_start, approved_collector_fingerprints)
  end

  defp empty_window_at(window_start, approved_collector_fingerprints) do
    %__MODULE__{
      window_start: window_start,
      approved_collector_fingerprints: approved_collector_fingerprints
    }
  end

  defp next_window(%__MODULE__{pending: %__MODULE__{} = pending}, _observed_at),
    do: %{pending | pending: nil}

  defp next_window(%__MODULE__{} = window, observed_at) do
    immediate_successor = DateTime.add(window.window_start, @window_seconds, :second)
    live_window = BoundedCounter.window_start(observed_at, @window_seconds, @offset_seconds)
    next_start = Enum.max([immediate_successor, live_window], DateTime)

    empty_window_at(next_start, window.approved_collector_fingerprints)
  end

  defp sanitize(%{"type" => "ris_message", "data" => %{"type" => type}}, _window, _receipt_at)
       when type != "UPDATE",
       do: {:error, :unsupported_message}

  defp sanitize(
         %{
           "type" => "ris_message",
           "data" =>
             %{
               "type" => "UPDATE",
               "timestamp" => timestamp,
               "host" => collector,
               "peer" => peer,
               "peer_asn" => peer_asn,
               "id" => message_id
             } = update
         },
         window,
         receipt_at
       ) do
    announcements = Map.get(update, "announcements", [])
    withdrawals = Map.get(update, "withdrawals", [])

    with {:ok, occurred_at} <- provider_time(timestamp, receipt_at),
         {:ok, collector_fingerprint} <- collector_fingerprint(collector, window),
         {:ok, peer_fingerprint} <- peer_fingerprint(peer),
         :ok <- validate_base_fields(peer_asn, message_id),
         true <- is_list(announcements),
         true <- is_list(withdrawals) do
      {:ok,
       %{
         occurred_at: occurred_at,
         collector_fingerprint: collector_fingerprint,
         peer_fingerprint: peer_fingerprint,
         announcements: announcements,
         withdrawals: withdrawals
       }}
    else
      false -> {:error, :invalid_update}
      {:error, _reason} = error -> error
    end
  end

  defp sanitize(
         %{"type" => "ris_message", "data" => %{"type" => "UPDATE"}},
         _window,
         _receipt_at
       ),
       do: {:error, :invalid_update}

  defp sanitize(_frame, _window, _receipt_at), do: {:error, :unsupported_message}

  defp provider_time(timestamp, receipt_at) do
    with {:ok, time_us} <- timestamp_microseconds(timestamp),
         {:ok, occurred_at} <- DateTime.from_unix(time_us, :microsecond),
         :ok <- validate_timestamp_bounds(time_us, receipt_at) do
      {:ok, occurred_at}
    else
      {:error, :timestamp_too_old} = error -> error
      {:error, :timestamp_in_future} = error -> error
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp_microseconds(timestamp)
       when is_integer(timestamp) and timestamp >= 0 and timestamp <= @max_unix_second,
       do: {:ok, timestamp * 1_000_000}

  defp timestamp_microseconds(timestamp)
       when is_float(timestamp) and timestamp >= 0.0 and timestamp <= @max_unix_second do
    try do
      {:ok, round(timestamp * 1_000_000)}
    rescue
      ArithmeticError -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp_microseconds(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_timestamp_bounds(time_us, receipt_at) do
    receipt_time_us = DateTime.to_unix(receipt_at, :microsecond)

    cond do
      time_us < receipt_time_us - @past_bound_microseconds ->
        {:error, :timestamp_too_old}

      time_us > receipt_time_us + @future_bound_microseconds ->
        {:error, :timestamp_in_future}

      true ->
        :ok
    end
  end

  defp collector_fingerprint(collector, window) do
    if valid_collector?(collector) do
      collector_fingerprint = fingerprint(collector)

      if MapSet.member?(window.approved_collector_fingerprints, collector_fingerprint) do
        {:ok, collector_fingerprint}
      else
        {:error, :unapproved_collector}
      end
    else
      {:error, :invalid_collector}
    end
  end

  defp peer_fingerprint(peer) do
    with true <- is_binary(peer),
         true <- byte_size(peer) in 1..39,
         {:ok, parsed_address} <- parse_ip(peer) do
      {:ok, fingerprint(pack_address(parsed_address))}
    else
      _invalid -> {:error, :invalid_peer}
    end
  end

  defp validate_base_fields(peer_asn, message_id) do
    valid_peer_asn? = valid_peer_asn?(peer_asn)
    valid_message_id? = is_binary(message_id) and byte_size(message_id) > 0

    if valid_peer_asn? and valid_message_id?, do: :ok, else: {:error, :invalid_update}
  end

  defp valid_peer_asn?(peer_asn) when is_binary(peer_asn) do
    byte_size(peer_asn) in 1..10 and Regex.match?(@peer_asn_pattern, peer_asn) and
      case Integer.parse(peer_asn) do
        {number, ""} -> number in 0..@uint32_max
        _invalid -> false
      end
  end

  defp valid_peer_asn?(_peer_asn), do: false

  defp route_observation(window, observation, delta, receipt_at) do
    cond do
      delta.announced + delta.withdrawn == 0 ->
        {:ok, window}

      elapsed?(window, receipt_at) ->
        {:close_required, window}

      true ->
        event_window_start =
          BoundedCounter.window_start(
            observation.occurred_at,
            @window_seconds,
            @offset_seconds
          )

        route_open_observation(window, observation, delta, event_window_start)
    end
  end

  defp route_open_observation(window, observation, delta, event_window_start) do
    successor_start = DateTime.add(window.window_start, @window_seconds, :second)

    case DateTime.compare(event_window_start, window.window_start) do
      :lt ->
        {:drop, :late_event, window}

      :eq ->
        aggregate_current(window, observation, delta)

      :gt ->
        if DateTime.compare(event_window_start, successor_start) == :eq do
          aggregate_pending(window, observation, delta, successor_start)
        else
          {:drop, :window_ahead, window}
        end
    end
  end

  defp aggregate_current(window, observation, delta) do
    case aggregate_window(window, observation, delta) do
      {:ok, updated_window} -> {:ok, updated_window}
      {:drop, reason, updated_window} -> {:drop, reason, updated_window}
    end
  end

  defp aggregate_pending(window, observation, delta, successor_start) do
    pending =
      window.pending ||
        empty_window_at(successor_start, window.approved_collector_fingerprints)

    case aggregate_window(pending, observation, delta) do
      {:ok, updated_pending} ->
        {:ok, %{window | pending: updated_pending}}

      {:drop, reason, updated_pending} ->
        {:drop, reason, %{window | pending: updated_pending}}
    end
  end

  defp aggregate_window(window, observation, delta) do
    case prepare_fingerprints(window, observation, delta) do
      {:ok, prepared_window} ->
        {:ok, apply_delta(prepared_window, delta)}

      {:error, reason} when reason in [:peer_capacity, :collector_capacity] ->
        {:drop, reason, %{window | truncated: true}}
    end
  end

  defp prepare_fingerprints(window, observation, delta) do
    if delta.announced + delta.withdrawn == 0 do
      {:ok, window}
    else
      with {:ok, observed_collectors} <-
             put_bounded_fingerprint(
               window.observed_collector_fingerprints,
               observation.collector_fingerprint,
               4,
               :collector_capacity
             ),
           {:ok, peers} <-
             put_bounded_fingerprint(
               window.peer_fingerprints,
               observation.peer_fingerprint,
               @peer_capacity,
               :peer_capacity
             ) do
        {:ok,
         %{
           window
           | observed_collector_fingerprints: observed_collectors,
             peer_fingerprints: peers
         }}
      end
    end
  end

  defp put_bounded_fingerprint(fingerprints, fingerprint, capacity, reason) do
    cond do
      MapSet.member?(fingerprints, fingerprint) ->
        {:ok, fingerprints}

      MapSet.size(fingerprints) >= capacity ->
        {:error, reason}

      true ->
        {:ok, MapSet.put(fingerprints, fingerprint)}
    end
  end

  defp traverse_update(announcements, withdrawals) do
    initial_delta = %{
      announced: 0,
      withdrawn: 0,
      ipv4: 0,
      ipv6: 0,
      group_count: 0,
      prefix_count: 0,
      truncated: false
    }

    case traverse_announcement_groups(announcements, withdrawals, initial_delta) do
      {:cont, delta} -> {:ok, delta}
      {:halt, delta} -> {:ok, delta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp traverse_announcement_groups([], withdrawals, delta),
    do: traverse_prefixes(withdrawals, :withdrawn, delta, false)

  defp traverse_announcement_groups(
         _groups,
         _withdrawals,
         %{group_count: @announcement_group_capacity} = delta
       ),
       do: {:halt, %{delta | truncated: true}}

  defp traverse_announcement_groups(
         [%{"next_hop" => next_hop, "prefixes" => prefixes} | remaining_groups],
         withdrawals,
         delta
       )
       when is_list(prefixes) do
    if valid_ip?(next_hop) do
      group_delta = %{delta | group_count: delta.group_count + 1}
      unvisited_tail? = remaining_groups != [] or withdrawals != []

      case traverse_prefixes(prefixes, :announced, group_delta, unvisited_tail?) do
        {:cont, next_delta} ->
          traverse_announcement_groups(remaining_groups, withdrawals, next_delta)

        {:halt, next_delta} ->
          {:halt, next_delta}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_update}
    end
  end

  defp traverse_announcement_groups(
         [_invalid_group | _remaining_groups],
         _withdrawals,
         _delta
       ),
       do: {:error, :invalid_update}

  defp traverse_prefixes([], _kind, delta, _unvisited_tail?), do: {:cont, delta}

  defp traverse_prefixes(
         _prefixes,
         _kind,
         %{prefix_count: @prefix_capacity} = delta,
         _unvisited_tail?
       ),
       do: {:halt, %{delta | truncated: true}}

  defp traverse_prefixes([prefix | remaining_prefixes], kind, delta, unvisited_tail?) do
    case cidr_family(prefix) do
      {:ok, family} ->
        next_delta =
          delta
          |> increment_delta(kind)
          |> increment_delta(family)
          |> Map.update!(:prefix_count, &(&1 + 1))

        if next_delta.prefix_count == @prefix_capacity do
          if remaining_prefixes != [] or unvisited_tail? do
            {:halt, %{next_delta | truncated: true}}
          else
            {:cont, next_delta}
          end
        else
          traverse_prefixes(remaining_prefixes, kind, next_delta, unvisited_tail?)
        end

      :error ->
        {:error, :invalid_update}
    end
  end

  defp increment_delta(delta, field), do: Map.update!(delta, field, &(&1 + 1))

  defp apply_delta(window, delta) do
    window
    |> increment_window(:announced, delta.announced)
    |> increment_window(:withdrawn, delta.withdrawn)
    |> increment_window(:ipv4, delta.ipv4)
    |> increment_window(:ipv6, delta.ipv6)
    |> Map.update!(:truncated, &(&1 or delta.truncated))
  end

  defp increment_window(window, field, increment) do
    {count, truncated} = BoundedCounter.add(Map.fetch!(window, field), increment)

    window
    |> Map.put(field, count)
    |> Map.update!(:truncated, &(&1 or truncated))
  end

  defp cidr_family(prefix) when is_binary(prefix) and byte_size(prefix) in 1..43 do
    case String.split(prefix, "/", parts: 2) do
      [address, encoded_length] ->
        with true <- byte_size(address) in 1..39,
             true <- byte_size(encoded_length) in 1..3,
             true <- Regex.match?(~r/\A\d+\z/, encoded_length),
             {prefix_length, ""} <- Integer.parse(encoded_length),
             {:ok, parsed_address} <- parse_ip(address),
             true <- valid_prefix_length?(parsed_address, prefix_length) do
          {:ok, address_family(parsed_address)}
        else
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp cidr_family(_prefix), do: :error

  defp valid_ip?(address) when is_binary(address) and byte_size(address) in 1..39,
    do: match?({:ok, _address}, parse_ip(address))

  defp valid_ip?(_address), do: false

  defp parse_ip(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_strict_address()
  end

  defp pack_address({a, b, c, d}), do: <<a, b, c, d>>

  defp pack_address({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  defp valid_prefix_length?(address, prefix_length) when tuple_size(address) == 4,
    do: prefix_length in 0..32

  defp valid_prefix_length?(address, prefix_length) when tuple_size(address) == 8,
    do: prefix_length in 0..128

  defp address_family(address) when tuple_size(address) == 4, do: :ipv4
  defp address_family(address) when tuple_size(address) == 8, do: :ipv6

  defp fingerprint(identifier), do: :crypto.hash(:sha256, identifier)
end
