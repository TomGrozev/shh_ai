defmodule ShhAi.ProviderClient.UpdateAccumulatorTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient
  alias ShhAi.ProviderClient.StreamHandler.Accumulator

  describe "update_accumulator/4" do
    test "seeds from Accumulator.new/0 and applies first chunk" do
      acc = Accumulator.new()
      restore_start = 1_000
      restore_end = 1_500
      chunk_content = "hello"

      result = ProviderClient.update_accumulator(acc, restore_start, restore_end, chunk_content)

      assert %Accumulator{} = result
      assert result.restore_duration == 500
      assert result.assistant_content_chunks == ["hello"]
    end

    test "prepends new chunk content to existing chunks" do
      acc = %Accumulator{restore_duration: 1_000, assistant_content_chunks: ["a"]}
      restore_start = 5_000
      restore_end = 5_200
      chunk_content = "new"

      result = ProviderClient.update_accumulator(acc, restore_start, restore_end, chunk_content)

      assert result.restore_duration == 1_200
      assert result.assistant_content_chunks == ["new", "a"]
    end

    test "accumulates restore_duration across multiple calls" do
      acc = Accumulator.new()

      acc1 = ProviderClient.update_accumulator(acc, 0, 100, "first")
      acc2 = ProviderClient.update_accumulator(acc1, 200, 350, "second")

      assert acc2.restore_duration == 250
      assert acc2.assistant_content_chunks == ["second", "first"]
    end

    test "zero-content chunk is still prepended" do
      acc = Accumulator.new()

      result = ProviderClient.update_accumulator(acc, 0, 50, "")

      assert result.restore_duration == 50
      assert result.assistant_content_chunks == [""]
    end
  end
end
