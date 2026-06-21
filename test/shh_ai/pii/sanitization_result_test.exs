defmodule ShhAi.PII.SanitizationResultTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.SanitizationResult

  describe "struct fields" do
    test "has the expected fields" do
      result = %SanitizationResult{
        sanitized_messages: [],
        mapping: %{},
        reverse_index: %{},
        detection_counts: {0, 0},
        pii_info: %{detected_count: 0, sanitized_count: 0, preserved_count: 0, types: []}
      }

      assert result.sanitized_messages == []
      assert result.mapping == %{}
      assert result.reverse_index == %{}
      assert result.detection_counts == {0, 0}
      assert result.pii_info.types == []
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("%ShhAi.PII.SanitizationResult{}")
      end
    end
  end
end
