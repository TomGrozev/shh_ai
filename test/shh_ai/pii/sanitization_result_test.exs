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

  describe "from_5tuple/1" do
    test "builds struct from the 5-tuple shape" do
      sanitized = [%{"role" => "user", "content" => "My email is <EMAIL_1>"}]
      mapping = %{{:email, 1} => "john@example.com"}
      reverse_index = %{{"john@example.com", :email} => {:email, 1}}
      detection_counts = {1, 0}
      pii_info = %{detected_count: 1, sanitized_count: 1, preserved_count: 0, types: [:email]}

      result = SanitizationResult.from_5tuple({:ok, sanitized, mapping, reverse_index, detection_counts, pii_info})

      assert %SanitizationResult{} = result
      assert result.sanitized_messages == sanitized
      assert result.mapping == mapping
      assert result.reverse_index == reverse_index
      assert result.detection_counts == {1, 0}
      assert result.pii_info.types == [:email]
    end
  end
end
