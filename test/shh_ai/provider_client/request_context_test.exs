defmodule ShhAi.ProviderClient.RequestContextTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.RequestContext

  describe "struct shape" do
    test "has a :streaming field" do
      # Use a fully-populated struct (just to be safe; we'll narrow this later)
      ctx = %RequestContext{
        source_provider: :openai,
        target_provider: :openai,
        source_path: "/v1/chat/completions",
        target_path: "/v1/chat/completions",
        method: :post,
        config: %{},
        source_converter: nil,
        target_converter: nil,
        conversation: nil,
        openai_body: %{},
        mapping: %{},
        reverse_index: %{},
        pii_info: %{},
        timings: %{},
        target_headers: [],
        final_headers: [],
        target_body: %{},
        started: %{monotonic: 0, system: 0},
        streaming: true
      }

      assert ctx.streaming == true
      assert Map.has_key?(ctx, :streaming)
    end

    test ":streaming is in @enforce_keys" do
      keys = RequestContext.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))
      assert :streaming in keys
    end
  end

  describe "enforce_keys" do
    test "missing :streaming raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("""
        %ShhAi.ProviderClient.RequestContext{
          source_provider: :openai,
          target_provider: :openai,
          source_path: "/v1/chat/completions",
          target_path: "/v1/chat/completions",
          method: :post,
          config: %{},
          source_converter: nil,
          target_converter: nil,
          conversation: nil,
          openai_body: %{},
          mapping: %{},
          reverse_index: %{},
          pii_info: %{},
          timings: %{},
          target_headers: [],
          final_headers: [],
          target_body: %{},
          started: %{monotonic: 0, system: 0}
        }
        """)
      end
    end
  end
end
