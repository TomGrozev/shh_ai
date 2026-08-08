defmodule ShhAiWeb.DashboardLive.Helpers do
  @moduledoc """
  Shared helpers for DashboardLive components.
  """

  @doc """
  Converts a `NaiveDateTime` to microseconds since Unix epoch.
  Returns 0 for nil.
  """
  def naive_to_us(nil), do: 0

  def naive_to_us(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  @doc """
  Safely converts a string to an existing atom.
  Returns nil for non-binary input or if the atom doesn't exist.
  """
  def safe_to_existing_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  def safe_to_existing_atom(other), do: other

  @doc """
  Extracts the target provider atom from a list of events.
  Returns nil for an empty list.
  """
  def target_from_events([]), do: nil
  def target_from_events([first | _]), do: safe_to_existing_atom(first.target_provider)

  @doc """
  Parses a provider string and returns the corresponding atom.
  Returns nil for empty or unknown provider strings.
  """
  def parse_provider(""), do: nil
  def parse_provider("openai"), do: :openai
  def parse_provider("anthropic"), do: :anthropic
  def parse_provider("ollama"), do: :ollama
  def parse_provider(_), do: nil
end
