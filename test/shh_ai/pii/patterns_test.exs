defmodule ShhAi.PII.PatternsTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.Patterns

  setup do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "all/0" do
    test "returns list of compiled patterns" do
      patterns = Patterns.all()

      assert is_list(patterns)
      assert length(patterns) > 0

      # Each pattern should have required fields
      for pattern <- patterns do
        assert Map.has_key?(pattern, :type)
        assert Map.has_key?(pattern, :pattern)
        assert Map.has_key?(pattern, :confidence)
        assert Map.has_key?(pattern, :description)
      end
    end

    test "includes email pattern" do
      patterns = Patterns.all()

      email_patterns = Enum.filter(patterns, &(&1.type == :email))
      assert length(email_patterns) > 0
    end

    test "includes phone pattern" do
      patterns = Patterns.all()

      phone_patterns = Enum.filter(patterns, &(&1.type == :phone))
      assert length(phone_patterns) > 0
    end

    test "includes ssn pattern" do
      patterns = Patterns.all()

      ssn_patterns = Enum.filter(patterns, &(&1.type == :ssn))
      assert length(ssn_patterns) > 0
    end

    test "includes financial pattern" do
      patterns = Patterns.all()

      financial_patterns = Enum.filter(patterns, &(&1.type == :financial))
      assert length(financial_patterns) > 0
    end

    test "all patterns have confidence between 0 and 1" do
      patterns = Patterns.all()

      for pattern <- patterns do
        assert pattern.confidence >= 0.0
        assert pattern.confidence <= 1.0
      end
    end
  end

  describe "for_type/1" do
    test "returns patterns for specific type" do
      email_patterns = Patterns.for_type(:email)

      assert is_list(email_patterns)
      assert length(email_patterns) > 0

      for pattern <- email_patterns do
        assert pattern.type == :email
      end
    end

    test "returns empty list for unknown type" do
      patterns = Patterns.for_type(:unknown_type)
      assert patterns == []
    end
  end

  describe "load_into_persistent_term/0" do
    test "stores patterns in persistent_term" do
      # This should not raise
      assert :ok = Patterns.load_into_persistent_term()

      # Verify patterns are accessible
      patterns = Patterns.all()
      assert is_list(patterns)
    end
  end
end
