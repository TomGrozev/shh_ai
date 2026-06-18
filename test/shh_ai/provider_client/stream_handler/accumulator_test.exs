defmodule ShhAi.ProviderClient.StreamHandler.AccumulatorTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.StreamHandler.Accumulator

  describe "struct fields" do
    test "has zero-value defaults" do
      acc = %Accumulator{restore_duration: 0, assistant_content_chunks: []}
      assert acc.restore_duration == 0
      assert acc.assistant_content_chunks == []
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("""
        %ShhAi.ProviderClient.StreamHandler.Accumulator{restore_duration: 0}
        """)
      end
    end
  end

  describe "new/0" do
    test "returns the empty accumulator" do
      acc = Accumulator.new()
      assert %Accumulator{} = acc
      assert acc.restore_duration == 0
      assert acc.assistant_content_chunks == []
    end
  end
end
