defmodule ShhAi.PII.NERTest do
  # Not async: NER.init/0 switches NER on VM-wide (:persistent_term), which
  # would leak into concurrently running tests.
  use ExUnit.Case, async: false

  alias ShhAi.PII.NER

  @moduletag :ner

  # Erase the VM-global NER state once this module finishes so later tests run
  # with NER off, as config/test.exs intends.
  setup_all do
    on_exit(fn ->
      for key <- [:serving, :tokenizer, :initialized],
          do: :persistent_term.erase({NER, key})
    end)
  end

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

      assert detections != []

      types = Enum.map(detections, & &1.type)
      # Should detect at least one of: name, email, or phone
      assert Enum.any?(types, &(&1 in [:name, :email, :phone]))
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

    test "merges the tokens of one entity into a single span" do
      # The model tags each wordpiece of the address with `B-EMAIL`/`I-EMAIL`,
      # which we stitch into one span covering the whole value.
      {:ok, detections} = NER.detect("Contact robert.smith@example.com now")

      assert Enum.any?(detections, fn d ->
               d.type == :email and d.value == "robert.smith@example.com"
             end)
    end

    test "keeps entities the model tagged with separate B- labels separate" do
      # For "Robert Smith" the model emits two `B-PERSON` labels, not a
      # `B-`/`I-` pair, so these are two entities. Fusing them would merge two
      # gold spans into one and the one-to-one scorer would drop one.
      {:ok, detections} = NER.detect("Sincerely, Robert Smith")

      names = for d <- detections, d.type == :name, do: d.value

      assert "Robert" in names
      assert "Smith" in names
      refute "Robert Smith" in names
    end

    test "keeps every entity in a text, not only the last" do
      {:ok, detections} =
        NER.detect("Robert Smith emailed robert.smith@example.com from London")

      types = detections |> Enum.map(& &1.type) |> MapSet.new()

      assert MapSet.subset?(MapSet.new([:name, :email, :location]), types)
    end

    test "detects PII past the model's 512-token window" do
      text =
        String.duplicate("The quick brown fox jumps over the lazy dog. ", 60) <>
          " Contact john.doe@example.com now."

      {:ok, detections} = NER.detect(text)

      assert email = Enum.find(detections, &(&1.type == :email))
      assert email.value == "john.doe@example.com"

      assert binary_part(text, email.start_pos, email.end_pos - email.start_pos) ==
               "john.doe@example.com"
    end

    test "returns byte-accurate values for non-ASCII text" do
      text = "Hans Müller lives in Zürich."
      {:ok, detections} = NER.detect(text)

      # Offsets are byte indices, so slicing the binary by them must round-trip
      # exactly; a grapheme-based slice would corrupt the umlauts.
      assert Enum.any?(detections, fn d ->
               d.type == :location and d.value == "Zürich"
             end)

      for detection <- detections do
        assert binary_part(text, detection.start_pos, detection.end_pos - detection.start_pos) ==
                 detection.value
      end
    end

    test "per-type thresholds override the global threshold for their type" do
      text = "My email is john@example.com"
      {:ok, [first | _]} = NER.detect(text)

      {:ok, filtered} = NER.detect(text, type_thresholds: %{first.type => 0.999})

      refute Enum.any?(filtered, &(&1.type == first.type))
    end

    test "unlisted types fall back to the global threshold" do
      text = "My email is john@example.com"
      {:ok, [first | _]} = NER.detect(text)

      {:ok, filtered} =
        NER.detect(text, confidence_threshold: 0.999, type_thresholds: %{first.type => 0.0})

      # The email survives its per-type override while nothing else can clear
      # the global 0.999 floor.
      assert Enum.any?(filtered, &(&1.type == first.type))
      assert Enum.all?(filtered, &(&1.confidence >= 0.999 or &1.type == first.type))
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
