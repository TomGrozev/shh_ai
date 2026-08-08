defmodule ShhAiWeb.DashboardLive.Helpers do
  @moduledoc """
  Thin helpers for dashboard LiveView templates.

  Most formatting and conversion logic has been consolidated into `ShhAi.Utils`,
  `ShhAi.Audit.EventRecord`, and `ShhAi.Metrics.Event`. This module retains only
  view-specific helpers that don't belong elsewhere.
  """

  @doc """
  Extracts the target provider string from a list of events.
  Returns nil for an empty list.
  """
  def target_from_events([]), do: nil
  def target_from_events([first | _]), do: first.target_provider

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
