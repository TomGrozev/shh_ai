defmodule ShhAi.ProviderClient.StreamHandler.RequestMetaTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.StreamHandler.RequestMeta

  describe "struct fields" do
    test "holds the three required fields" do
      metrics_opts = %{
        source_provider: :openai,
        target_provider: "gpt-4",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      }

      meta = %RequestMeta{
        start_time: 1_700_000_000_000,
        metrics_opts: metrics_opts,
        conversation_id: "conv-123"
      }

      assert meta.start_time == 1_700_000_000_000
      assert meta.metrics_opts == metrics_opts
      assert meta.conversation_id == "conv-123"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("""
        %ShhAi.ProviderClient.StreamHandler.RequestMeta{start_time: 0}
        """)
      end
    end
  end

  describe "new/1" do
    test "builds struct from keyword list" do
      metrics_opts = %{
        source_provider: :openai,
        target_provider: "gpt-4",
        request_path: "/v1/chat/completions",
        method: "POST",
        streaming: true
      }

      meta =
        RequestMeta.new(
          start_time: 1_700_000_000_000,
          metrics_opts: metrics_opts,
          conversation_id: "conv-123"
        )

      assert %RequestMeta{} = meta
      assert meta.start_time == 1_700_000_000_000
      assert meta.metrics_opts == metrics_opts
      assert meta.conversation_id == "conv-123"
    end

    test "raises when required key is missing" do
      assert_raise KeyError, fn ->
        RequestMeta.new(start_time: 0, conversation_id: "conv-123")
      end
    end
  end
end
