defmodule ShhAiWeb.DashboardEventHelpers do
  @moduledoc """
  Shared helpers for dashboard LiveView tests that work with Event structs.
  """

  alias ShhAi.Metrics.Event

  def make_event(overrides \\ %{}) do
    now = System.system_time(:microsecond)

    default = %Event{
      id: "ev-#{System.unique_integer([:positive])}",
      started_at: now - 100_000,
      ended_at: now,
      duration_ms: 100.0,
      source_provider: :openai,
      target_provider: "anthropic",
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      conversation_id: nil,
      pii_detected_count: 0,
      pii_sanitized_count: 0,
      pii_preserved_count: 0,
      pii_types: [],
      timings: %{
        pii_ms: 5.0,
        backend_ms: 80.0,
        restore_ms: 2.0,
        source_conversion_ms: 1.0,
        target_conversion_ms: 1.0
      },
      error: nil,
      inserted_at: now
    }

    Map.merge(default, overrides)
  end
end
