defmodule Worldloom.Signals.BoundedCounter do
  @uint32_max 4_294_967_295

  @spec add(non_neg_integer(), non_neg_integer()) :: {non_neg_integer(), boolean()}
  def add(counter, increment)
      when is_integer(counter) and counter >= 0 and counter <= @uint32_max and
             is_integer(increment) and increment >= 0 do
    total = counter + increment
    {min(total, @uint32_max), total > @uint32_max}
  end

  def add(_counter, _increment) do
    raise ArgumentError,
          "counter must be an unsigned 32-bit integer and increment must be a non-negative integer"
  end

  @spec window_start(DateTime.t(), pos_integer(), non_neg_integer()) :: DateTime.t()
  def window_start(%DateTime{} = occurred_at, width_seconds, offset_seconds)
      when is_integer(width_seconds) and width_seconds in 1..60 and
             is_integer(offset_seconds) and offset_seconds >= 0 and
             offset_seconds < width_seconds do
    unix_second = DateTime.to_unix(occurred_at, :second)
    unix_start = unix_second - Integer.mod(unix_second - offset_seconds, width_seconds)
    DateTime.from_unix!(unix_start, :second)
  end

  def window_start(_occurred_at, _width_seconds, _offset_seconds) do
    raise ArgumentError,
          "window time must be a DateTime, width must be from 1 through 60, and offset must be inside the window"
  end
end
