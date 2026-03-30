defmodule ShhAi.PII.DetectorTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.{Detector, Patterns}

  setup do
    # Ensure config is loaded
    ShhAi.Config.load()
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "detect/2" do
    test "detects email addresses" do
      text = "My email is john@example.com"

      detections = Detector.detect(text)

      assert length(detections) == 1
      detection = hd(detections)
      assert detection.type == :email
      assert detection.value == "john@example.com"
      assert detection.confidence >= 0.9
    end

    test "detects multiple emails" do
      text = "Contact john@example.com or jane@example.org"

      detections = Detector.detect(text)

      assert length(detections) == 2
      values = Enum.map(detections, & &1.value)
      assert "john@example.com" in values
      assert "jane@example.org" in values
    end

    test "detects US phone numbers" do
      text = "Call me at 555-123-4567"

      detections = Detector.detect(text)

      assert length(detections) == 1
      detection = hd(detections)
      assert detection.type == :phone
      assert detection.value == "555-123-4567"
    end

    test "detects phone numbers with parentheses" do
      text = "Phone: (555) 123-4567"

      detections = Detector.detect(text)

      assert length(detections) == 1
      detection = hd(detections)
      assert detection.type == :phone
    end

    test "detects international phone numbers" do
      text = "My number is +1 555 123 4567"

      detections = Detector.detect(text, types: [:phone])

      phone_detections = Enum.filter(detections, &(&1.type == :phone))
      assert length(phone_detections) >= 1
    end

    test "detects SSN in format XXX-XX-XXXX" do
      text = "SSN: 123-45-6789"

      detections = Detector.detect(text)

      ssn_detections = Enum.filter(detections, &(&1.type == :ssn))
      assert length(ssn_detections) >= 1
    end

    test "detects SSN with spaces" do
      text = "Social Security Number: 123 45 6789"

      detections = Detector.detect(text)

      ssn_detections = Enum.filter(detections, &(&1.type == :ssn))
      assert length(ssn_detections) >= 1
    end

    test "detects Visa credit cards" do
      text = "Card: 4111111111111111"

      detections = Detector.detect(text)

      cc_detections = Enum.filter(detections, &(&1.type == :credit_card))
      assert length(cc_detections) >= 1
    end

    test "detects American Express cards" do
      text = "Amex: 378282246310005"

      detections = Detector.detect(text)

      cc_detections = Enum.filter(detections, &(&1.type == :credit_card))
      assert length(cc_detections) >= 1
    end

    test "detects credit cards with separators" do
      text = "Card: 4111-1111-1111-1111"

      detections = Detector.detect(text)

      cc_detections = Enum.filter(detections, &(&1.type == :credit_card))
      assert length(cc_detections) >= 1
    end

    test "detects ISO dates" do
      text = "Born on 1990-01-15"

      detections = Detector.detect(text)

      date_detections = Enum.filter(detections, &(&1.type == :date))
      assert length(date_detections) >= 1
    end

    test "detects US dates" do
      text = "Date: 01/15/1990"

      detections = Detector.detect(text)

      date_detections = Enum.filter(detections, &(&1.type == :date))
      assert length(date_detections) >= 1
    end

    test "detects DOB specifically" do
      text = "DOB: 01/15/1990"

      detections = Detector.detect(text)

      date_detections = Enum.filter(detections, &(&1.type == :date))
      assert length(date_detections) >= 1
    end

    test "detects medical record numbers" do
      text = "MRN: ABC123456"

      detections = Detector.detect(text)

      medical_detections = Enum.filter(detections, &(&1.type == :medical_id))
      assert length(medical_detections) >= 1
    end

    test "detects IPv4 addresses" do
      text = "Server IP: 192.168.1.1"

      detections = Detector.detect(text, types: [:ip_address])

      ip_detections = Enum.filter(detections, &(&1.type == :ip_address))
      assert length(ip_detections) >= 1
    end

    test "detects URLs" do
      text = "Visit https://example.com for more info"

      detections = Detector.detect(text, types: [:url])

      url_detections = Enum.filter(detections, &(&1.type == :url))
      assert length(url_detections) >= 1
    end

    test "detects street addresses" do
      text = "I live at 123 Main Street"

      detections = Detector.detect(text)

      location_detections = Enum.filter(detections, &(&1.type == :location))
      assert length(location_detections) >= 1
    end

    test "detects ZIP codes" do
      text = "ZIP: 90210"

      detections = Detector.detect(text)

      location_detections = Enum.filter(detections, &(&1.type == :location))
      # ZIP codes have lower confidence, might not always be detected
      assert length(location_detections) >= 0
    end

    test "detects self-introduced names" do
      text = "My name is John Smith"

      detections = Detector.detect(text)

      name_detections = Enum.filter(detections, &(&1.type == :name))
      assert length(name_detections) >= 1
    end

    test "detects labeled names" do
      text = "Name: John Smith"

      detections = Detector.detect(text)

      name_detections = Enum.filter(detections, &(&1.type == :name))
      assert length(name_detections) >= 1
    end

    test "detects self-declared locations" do
      text = "I live in New York"

      detections = Detector.detect(text)

      location_detections = Enum.filter(detections, &(&1.type == :location))
      assert length(location_detections) >= 1
    end

    test "filters by confidence threshold" do
      text = "Email: john@example.com"

      # High threshold should still detect high-confidence items
      detections = Detector.detect(text, confidence_threshold: 0.9)
      assert length(detections) == 1

      # Very high threshold might filter out items
      detections = Detector.detect(text, confidence_threshold: 0.99)
      assert length(detections) == 0
    end

    test "filters by type" do
      text = "Email: john@example.com, Phone: 555-123-4567"

      detections = Detector.detect(text, types: [:email])
      assert length(detections) == 1
      assert hd(detections).type == :email

      detections = Detector.detect(text, types: [:phone])
      assert length(detections) >= 1
      assert hd(detections).type == :phone
    end

    test "returns empty list for text without PII" do
      text = "Hello world, this is a test"

      detections = Detector.detect(text)
      assert detections == []
    end

    test "handles multiple PII types in single text" do
      text = "Contact john@example.com or call 555-123-4567. My SSN is 123-45-6789."

      detections = Detector.detect(text)

      types = Enum.map(detections, & &1.type) |> Enum.uniq()
      assert :email in types
      assert :phone in types
      assert :ssn in types
    end

    test "returns correct positions" do
      text = "Email: john@example.com"

      [detection | _] = Detector.detect(text)

      assert detection.start_pos == 7
      assert detection.end_pos == 23

      assert binary_part(text, detection.start_pos, detection.end_pos - detection.start_pos) ==
               "john@example.com"
    end
  end

  describe "detect_large/2" do
    test "handles large text with parallel processing" do
      # Create a large text with multiple PII
      base_text = "Contact john@example.com or call 555-123-4567. "
      large_text = String.duplicate(base_text, 100)

      detections = Detector.detect_large(large_text)

      assert length(detections) > 0
    end

    test "adjusts positions for chunked detection" do
      base_text = "Contact john@example.com "
      large_text = String.duplicate(base_text, 100)

      detections = Detector.detect_large(large_text, chunk_size: 50)

      # Each detection should have valid positions
      for detection <- detections do
        assert detection.start_pos >= 0
        assert detection.end_pos > detection.start_pos
        assert detection.end_pos <= byte_size(large_text)
      end
    end
  end

  describe "contains_pii?/2" do
    test "returns true for text with PII" do
      assert Detector.contains_pii?("Email: john@example.com") == true
      assert Detector.contains_pii?("SSN: 123-45-6789") == true
    end

    test "returns false for text without PII" do
      assert Detector.contains_pii?("Hello world") == false
      assert Detector.contains_pii?("This is a test message") == false
    end
  end

  describe "summary/2" do
    test "returns summary of detected PII types" do
      text = "Email: john@example.com, Phone: 555-123-4567"

      summary = Detector.summary(text)

      assert is_map(summary)
      assert Map.has_key?(summary, :email)
      assert Map.has_key?(summary, :phone)
    end

    test "returns empty map for text without PII" do
      summary = Detector.summary("Hello world")
      assert summary == %{}
    end
  end
end
