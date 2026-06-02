defmodule ShhAi.TestSupport.DataGeneratorTest do
  @moduledoc """
  Unit tests for the DataGenerator module.
  """

  use ExUnit.Case, async: true

  alias ShhAi.TestSupport.DataGenerator

  @sizes [:small, :medium, :large, :xlarge, :xxlarge, :huge]
  @size_targets %{
    small: 1_024,
    medium: 10_240,
    large: 51_200,
    xlarge: 102_400,
    xxlarge: 512_000,
    huge: 1_048_576
  }

  describe "generate_text/1" do
    test "produces text containing PII of expected types" do
      text = DataGenerator.generate_text(seed: 42, size: :small)

      assert is_binary(text)
      assert text != ""

      # Check for at least some recognizable PII patterns
      assert text =~ "@" or text =~ "-" or text =~ "."
    end

    test "same seed produces identical output" do
      text1 = DataGenerator.generate_text(seed: 42, size: :small)
      text2 = DataGenerator.generate_text(seed: 42, size: :small)

      assert text1 == text2
    end

    test "different seeds produce different output" do
      text1 = DataGenerator.generate_text(seed: 42, size: :small)
      text2 = DataGenerator.generate_text(seed: 43, size: :small)

      assert text1 != text2
    end

    test "size options produce approximately correct payload sizes" do
      for size <- @sizes do
        text = DataGenerator.generate_text(seed: 42, size: size)
        target = Map.fetch!(@size_targets, size)
        actual = byte_size(text)

        assert actual >= div(target, 2),
               "Expected #{size} (>= #{div(target, 2)} bytes) but got #{actual} bytes"

        assert actual <= target * 2,
               "Expected #{size} (<= #{target * 2} bytes) but got #{actual} bytes"
      end
    end

    test "logs seed to stdout" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          DataGenerator.generate_text(seed: 999, size: :small)
        end)

      assert output =~ "[DataGenerator] seed=999"
    end

    test "PERF_SEED=random uses a random seed" do
      # Set the env var, generate twice, unset
      original = System.get_env("PERF_SEED")
      System.put_env("PERF_SEED", "random")

      try do
        text1 = DataGenerator.generate_text(size: :small)
        text2 = DataGenerator.generate_text(size: :small)

        assert text1 != text2
      after
        if original,
          do: System.put_env("PERF_SEED", original),
          else: System.delete_env("PERF_SEED")
      end
    end

    test "PERF_SEED env var overrides default" do
      original = System.get_env("PERF_SEED")
      System.put_env("PERF_SEED", "12345")

      try do
        text = DataGenerator.generate_text(size: :small)
        text_again = DataGenerator.generate_text(size: :small)

        assert text == text_again
      after
        if original,
          do: System.put_env("PERF_SEED", original),
          else: System.delete_env("PERF_SEED")
      end
    end

    test "pii_types option filters embedded PII types" do
      text = DataGenerator.generate_text(seed: 42, size: :small, pii_types: [:email, :phone])

      # Should still contain @ signs from emails or - from phones
      assert text =~ "@" or text =~ "-"
    end
  end

  describe "generate_request/1" do
    test "produces valid OpenAI-format request body" do
      req = DataGenerator.generate_request(seed: 42, size: :small)

      assert is_map(req)
      assert Map.has_key?(req, "messages")
      assert is_list(req["messages"])
      assert length(req["messages"]) >= 1

      first_msg = hd(req["messages"])
      assert Map.has_key?(first_msg, "role")
      assert Map.has_key?(first_msg, "content")
    end

    test "same seed produces identical request" do
      req1 = DataGenerator.generate_request(seed: 42, size: :small)
      req2 = DataGenerator.generate_request(seed: 42, size: :small)

      assert req1 == req2
    end

    test "different seeds produce different requests" do
      req1 = DataGenerator.generate_request(seed: 42, size: :small)
      req2 = DataGenerator.generate_request(seed: 43, size: :small)

      assert req1 != req2
    end

    test "request content is approximately correct size" do
      req = DataGenerator.generate_request(seed: 42, size: :medium)

      content =
        req["messages"] |> Enum.find(fn m -> m["role"] == "user" end) |> Map.get("content")

      target = @size_targets.medium
      actual = byte_size(content)

      assert actual >= div(target, 2)
      assert actual <= target * 2
    end
  end
end
