defmodule Worldloom.Signals.Backoff do
  @maximum_attempt 8
  @maximum_delay 300_000
  @minimum_delay 1_000

  @spec delay(non_neg_integer(), float()) :: pos_integer()
  def delay(attempt, random_fraction)
      when is_integer(attempt) and attempt >= 0 and is_float(random_fraction) and
             random_fraction >= 0.0 and random_fraction <= 1.0 do
    base_delay =
      min(@maximum_delay, @minimum_delay * Integer.pow(2, min(attempt, @maximum_attempt)))

    jitter_factor = 0.8 + random_fraction * 0.4

    base_delay
    |> Kernel.*(jitter_factor)
    |> round()
    |> max(@minimum_delay)
    |> min(@maximum_delay)
  end

  def delay(_attempt, _random_fraction) do
    raise ArgumentError,
          "attempt must be non-negative and random fraction must be between 0.0 and 1.0"
  end
end
