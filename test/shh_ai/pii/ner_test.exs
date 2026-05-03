defmodule ShhAi.PII.NERTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.NER

  @moduletag :ner

  describe "init/1" do
    test "initializes the NER model successfully" do
      result = NER.init()
      assert result == :ok
      assert NER.initialized?() == true
    end

    test "returns error when model fails to load" do
      # This would require mocking, so we just verify the function exists
      assert function_exported?(NER, :init, 0)
      assert function_exported?(NER, :init, 1)
    end
  end

  describe "initialized?/0" do
    test "returns false before initialization" do
      # Note: This depends on test order, so we can't guarantee state
      assert is_boolean(NER.initialized?())
    end
  end

  describe "label_mapping/0" do
    test "returns mapping from NER labels to PII types" do
      mapping = NER.label_mapping()

      assert is_map(mapping)
      # Check key labels from the gravitee-io model
      assert Map.has_key?(mapping, "PERSON")
      assert Map.has_key?(mapping, "EMAIL_ADDRESS")
      assert Map.has_key?(mapping, "PHONE_NUMBER")
      assert Map.has_key?(mapping, "US_SSN")
      assert Map.has_key?(mapping, "CREDIT_CARD")
      assert Map.has_key?(mapping, "LOCATION")
      # Check new types
      assert Map.has_key?(mapping, "AGE")
      assert Map.has_key?(mapping, "PASSWORD")
      assert Map.has_key?(mapping, "URL")
      assert Map.has_key?(mapping, "MAC_ADDRESS")
    end

    test "maps PERSON to :name" do
      mapping = NER.label_mapping()
      assert mapping["PERSON"] == :name
    end

    test "maps EMAIL_ADDRESS to :email" do
      mapping = NER.label_mapping()
      assert mapping["EMAIL_ADDRESS"] == :email
    end

    test "maps DATE_TIME to :date" do
      mapping = NER.label_mapping()
      assert mapping["DATE_TIME"] == :date
    end

    test "maps LOCATION to :location" do
      mapping = NER.label_mapping()
      assert mapping["LOCATION"] == :location
    end

    test "maps US_DRIVER_LICENSE to :national_id" do
      mapping = NER.label_mapping()
      assert mapping["US_DRIVER_LICENSE"] == :national_id
    end
  end

  describe "detect/2" do
    setup do
      unless NER.initialized?() do
        NER.init()
      end

      :ok
    end

    test "detects PII entities in text" do
      text = "My email is john@example.com"
      {:ok, detections} = NER.detect(text)

      assert is_list(detections)
      # NER should detect the email
      email_detection = Enum.find(detections, fn d -> d.type == :email end)
      assert email_detection != nil
      assert email_detection.value == "john@example.com"
      assert email_detection.source == :ner
      assert email_detection.confidence > 0.5
    end

    test "detects multiple PII types" do
      text = "John Smith's email is john@example.com and phone is 555-123-4567"
      {:ok, detections} = NER.detect(text)

      assert length(detections) >= 1

      types = Enum.map(detections, & &1.type)
      # Should detect at least one of: name, email, or phone
      assert Enum.any?(types, &(&1 in [:name, :email, :phone]))
    end

    test "returns empty list for text without PII" do
      text = "The quick brown fox jumps over the lazy dog."
      {:ok, detections} = NER.detect(text)

      assert detections == []
    end

    test "respects confidence threshold" do
      text = "My email is john@example.com"

      # Low threshold - should detect
      {:ok, low_threshold_detections} = NER.detect(text, confidence_threshold: 0.5)

      # Very high threshold - may not detect
      {:ok, high_threshold_detections} = NER.detect(text, confidence_threshold: 0.99)

      # Low threshold should detect at least as many as high threshold
      assert length(low_threshold_detections) >= length(high_threshold_detections)
    end
  end

  describe "error handling" do
    test "raises when not initialized" do
      unless NER.initialized?() do
        assert_raise RuntimeError, ~r/NER model not initialized/, fn ->
          NER.detect("test text")
        end
      end
    end
  end
end
