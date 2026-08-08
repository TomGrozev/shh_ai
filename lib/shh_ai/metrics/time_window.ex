defmodule ShhAi.Metrics.TimeWindow do
  @moduledoc """
  Time window conversions for metrics queries.
  """

  @windows %{
    minute: 60,
    hour: 3_600,
    day: 86_400,
    week: 604_800
  }

  @doc "Returns seconds for the given window atom."
  @spec to_seconds(atom()) :: non_neg_integer()
  def to_seconds(window) do
    Map.get(@windows, window, @windows.day)
  end

  @doc "Returns microseconds for the given window atom."
  @spec to_microseconds(atom()) :: non_neg_integer()
  def to_microseconds(window) do
    to_seconds(window) * 1_000_000
  end

  @doc "Returns NaiveDateTime for 'now minus window'."
  @spec to_naive_since(atom()) :: NaiveDateTime.t()
  def to_naive_since(window) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-to_seconds(window), :second)
  end
end
