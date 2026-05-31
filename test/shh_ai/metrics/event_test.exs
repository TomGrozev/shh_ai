defmodule ShhAi.Metrics.EventTest do
  use ExUnit.Case, async: true

  alias ShhAi.Metrics.Event

  defp build_event(overrides \\ []) do
    defaults = [
      id: "evt-001",
      started_at: 1_700_000_000_000_000,
      ended_at: 1_700_000_150_000_000,
      duration_ms: 150.0,
      source_provider: :openai,
      target_provider: "anthropic",
      request_path: "/v1/chat/completions",
      method: "POST",
      streaming: false,
      status: 200,
      pii_detected_count: 3,
      pii_sanitized_count: 2,
      pii_preserved_count: 1,
      pii_types: [:email, :phone],
      timings: %{
        pii_ms: 5.0,
        backend_ms: 140.0,
        restore_ms: 2.0,
        source_conversion_ms: 1.5,
        target_conversion_ms: 1.5
      },
      error: nil,
      inserted_at: 1_700_000_150_000_000
    ]

    struct!(Event, Keyword.merge(defaults, overrides))
  end

  describe "from_telemetry/2" do
    test "creates event with full measurements and metadata" do
      now = System.system_time(:microsecond)

      measurements = %{
        duration: 150_000,
        pii_duration: 5_000,
        backend_duration: 140_000,
        restore_duration: 2_000,
        source_conversion_duration: 1_500,
        target_conversion_duration: 1_500,
        pii_detected_count: 3,
        pii_sanitized_count: 2,
        pii_preserved_count: 1,
        pii_types: [:email, :phone]
      }

      metadata = %{
        id: "evt-001",
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true,
        status: 200,
        started_at: now - 150_000
      }

      event = Event.from_telemetry(measurements, metadata)

      assert event.id == "evt-001"
      assert event.source_provider == :openai
      assert event.target_provider == "anthropic"
      assert event.request_path == "/v1/chat/completions"
      assert event.method == "POST"
      assert event.streaming == true
      assert event.status == 200
      assert event.duration_ms == 150.0
      assert event.pii_detected_count == 3
      assert event.pii_sanitized_count == 2
      assert event.pii_preserved_count == 1
      assert event.pii_types == [:email, :phone]
      assert event.started_at == now - 150_000
      assert event.ended_at >= now
      assert event.inserted_at >= now
      assert event.error == nil

      assert event.timings == %{
        pii_ms: 5.0,
        backend_ms: 140.0,
        restore_ms: 2.0,
        source_conversion_ms: 1.5,
        target_conversion_ms: 1.5
      }
    end

    test "creates event with minimal measurements (only required keys)" do
      measurements = %{}

      metadata = %{
        id: "evt-002",
        source_provider: :anthropic,
        target_provider: "openai",
        request_path: "/v1/messages",
        method: "GET"
      }

      event = Event.from_telemetry(measurements, metadata)

      assert event.id == "evt-002"
      assert event.source_provider == :anthropic
      assert event.target_provider == "openai"
      assert event.request_path == "/v1/messages"
      assert event.method == "GET"
    end

    test "raises when required metadata keys are missing" do
      measurements = %{duration: 100_000}

      assert_raise KeyError, fn ->
        Event.from_telemetry(measurements, %{
          source_provider: :openai,
          target_provider: "anthropic",
          request_path: "/v1/chat/completions",
          method: "POST"
        })
      end

      assert_raise KeyError, fn ->
        Event.from_telemetry(measurements, %{
          id: "evt-003",
          target_provider: "anthropic",
          request_path: "/v1/chat/completions",
          method: "POST"
        })
      end

      assert_raise KeyError, fn ->
        Event.from_telemetry(measurements, %{
          id: "evt-003",
          source_provider: :openai,
          request_path: "/v1/chat/completions",
          method: "POST"
        })
      end

      assert_raise KeyError, fn ->
        Event.from_telemetry(measurements, %{
          id: "evt-003",
          source_provider: :openai,
          target_provider: "anthropic",
          method: "POST"
        })
      end

      assert_raise KeyError, fn ->
        Event.from_telemetry(measurements, %{
          id: "evt-003",
          source_provider: :openai,
          target_provider: "anthropic",
          request_path: "/v1/chat/completions"
        })
      end
    end

    test "applies default values for optional fields" do
      now = System.system_time(:microsecond)

      event =
        Event.from_telemetry(%{}, %{
          id: "evt-004",
          source_provider: :ollama,
          target_provider: "ollama",
          request_path: "/api/generate",
          method: "POST"
        })

      assert event.streaming == false
      assert event.status == nil
      assert event.pii_detected_count == 0
      assert event.pii_sanitized_count == 0
      assert event.pii_preserved_count == 0
      assert event.pii_types == []
      assert event.error == nil
      assert event.duration_ms == 0.0

      assert event.timings == %{
        pii_ms: 0.0,
        backend_ms: 0.0,
        restore_ms: 0.0,
        source_conversion_ms: 0.0,
        target_conversion_ms: 0.0
      }

      assert event.ended_at >= now
      assert event.inserted_at == event.ended_at
      assert event.started_at == event.ended_at
    end

    test "nil duration gives 0.0" do
      event =
        Event.from_telemetry(%{duration: nil}, %{
          id: "evt-005",
          source_provider: :openai,
          target_provider: "anthropic",
          request_path: "/v1/chat/completions",
          method: "POST"
        })

      assert event.duration_ms == 0.0
    end

    test "handles PII fields correctly" do
      measurements = %{
        pii_detected_count: 5,
        pii_sanitized_count: 4,
        pii_preserved_count: 1,
        pii_types: [:email, :phone, :credit_card]
      }

      metadata = %{
        id: "evt-006",
        source_provider: :openai,
        target_provider: "anthropic",
        request_path: "/v1/chat/completions",
        method: "POST"
      }

      event = Event.from_telemetry(measurements, metadata)

      assert event.pii_detected_count == 5
      assert event.pii_sanitized_count == 4
      assert event.pii_preserved_count == 1
      assert event.pii_types == [:email, :phone, :credit_card]
    end

    test "handles error in metadata" do
      error = %{type: :timeout, message: "Request timed out"}

      event =
        Event.from_telemetry(%{}, %{
          id: "evt-007",
          source_provider: :openai,
          target_provider: "anthropic",
          request_path: "/v1/chat/completions",
          method: "POST",
          error: error
        })

      assert event.error == error
      assert event.status == nil
    end
  end

  describe "to_map/1" do
    test "round-trip preserves all data" do
      event = build_event()
      map = Event.to_map(event)

      assert map.id == event.id
      assert map.started_at == event.started_at
      assert map.ended_at == event.ended_at
      assert map.duration_ms == event.duration_ms
      assert map.target_provider == event.target_provider
      assert map.request_path == event.request_path
      assert map.method == event.method
      assert map.streaming == event.streaming
      assert map.status == event.status
      assert map.pii_detected_count == event.pii_detected_count
      assert map.pii_sanitized_count == event.pii_sanitized_count
      assert map.pii_preserved_count == event.pii_preserved_count
      assert map.timings == event.timings
      assert map.error == event.error
      assert map.inserted_at == event.inserted_at
    end

    test "converts source_provider atom to string" do
      event = build_event(source_provider: :openai)
      map = Event.to_map(event)

      assert map.source_provider == "openai"
    end

    test "converts pii_types atoms to strings" do
      event = build_event(pii_types: [:email, :phone, :credit_card])
      map = Event.to_map(event)

      assert map.pii_types == ["email", "phone", "credit_card"]
    end
  end

  describe "from_map/1" do
    test "round-trip with to_map/1" do
      original = build_event()
      map = Event.to_map(original)
      json_encoded = Jason.encode!(map)
      decoded = Jason.decode!(json_encoded)
      restored = Event.from_map(decoded)

      assert restored.id == original.id
      assert restored.started_at == original.started_at
      assert restored.ended_at == original.ended_at
      assert restored.duration_ms == original.duration_ms
      assert restored.source_provider == original.source_provider
      assert restored.target_provider == original.target_provider
      assert restored.request_path == original.request_path
      assert restored.method == original.method
      assert restored.streaming == original.streaming
      assert restored.status == original.status
      assert restored.pii_detected_count == original.pii_detected_count
      assert restored.pii_sanitized_count == original.pii_sanitized_count
      assert restored.pii_preserved_count == original.pii_preserved_count
      assert restored.pii_types == original.pii_types
      assert restored.timings == original.timings
      assert restored.error == original.error
      assert restored.inserted_at == original.inserted_at
    end

    test "converts string source_provider back to atom" do
      map = %{
        "id" => "evt-008",
        "started_at" => 1_700_000_000_000_000,
        "ended_at" => 1_700_000_150_000_000,
        "duration_ms" => 150.0,
        "source_provider" => "anthropic",
        "target_provider" => "openai",
        "request_path" => "/v1/messages",
        "method" => "GET",
        "streaming" => false,
        "status" => 200,
        "pii_detected_count" => 0,
        "pii_sanitized_count" => 0,
        "pii_preserved_count" => 0,
        "pii_types" => [],
        "timings" => %{
          "pii_ms" => 0.0,
          "backend_ms" => 0.0,
          "restore_ms" => 0.0,
          "source_conversion_ms" => 0.0,
          "target_conversion_ms" => 0.0
        },
        "error" => nil,
        "inserted_at" => 1_700_000_150_000_000
      }

      event = Event.from_map(map)

      assert event.source_provider == :anthropic
    end

    test "converts string pii_types back to atoms" do
      map = %{
        "id" => "evt-009",
        "started_at" => 1_700_000_000_000_000,
        "ended_at" => 1_700_000_150_000_000,
        "duration_ms" => 150.0,
        "source_provider" => "openai",
        "target_provider" => "anthropic",
        "request_path" => "/v1/chat/completions",
        "method" => "POST",
        "streaming" => false,
        "status" => 200,
        "pii_detected_count" => 3,
        "pii_sanitized_count" => 2,
        "pii_preserved_count" => 1,
        "pii_types" => ["email", "phone"],
        "timings" => %{
          "pii_ms" => 5.0,
          "backend_ms" => 140.0,
          "restore_ms" => 2.0,
          "source_conversion_ms" => 1.5,
          "target_conversion_ms" => 1.5
        },
        "error" => nil,
        "inserted_at" => 1_700_000_150_000_000
      }

      event = Event.from_map(map)

      assert event.pii_types == [:email, :phone]
    end

    test "raises when required keys are missing" do
      assert_raise KeyError, fn ->
        Event.from_map(%{})
      end
    end
  end

  describe "enforce_keys" do
    test "creating struct without required keys raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Kernel.struct!(Event, [])
      end
    end

    test "creating struct with only some required keys raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(Event, id: "evt-010", started_at: 1)
      end
    end
  end
end
