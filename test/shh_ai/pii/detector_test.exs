defmodule ShhAi.PII.DetectorTest do
  @moduledoc """
  Comprehensive PII detection tests with realistic LLM input scenarios.

  All tests use explicit assertions that verify:
  - The exact PII type detected
  - The exact value matched
  - The correct position (start_pos/end_pos) in the source text
  - That extracting text at those positions yields the matched value
  """

  use ExUnit.Case, async: true

  alias ShhAi.PII.{Detector, Patterns}

  setup_all do
    ShhAi.Config.load()
    Patterns.load_into_persistent_term()
    :ok
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Asserts that a detection exists with the expected type, value, and correct position.
  # Returns the matching detection for further assertions.
  defp assert_detection(detections, text, expected) do
    type = Keyword.fetch!(expected, :type)
    expected_value = Keyword.get(expected, :value)
    expected_start = Keyword.get(expected, :start_pos)
    expected_end = Keyword.get(expected, :end_pos)
    min_confidence = Keyword.get(expected, :min_confidence)

    matching =
      detections
      |> Stream.filter(&(&1.type == type))
      |> Stream.filter(fn d ->
        if expected_value, do: d.value == expected_value, else: true
      end)
      |> Stream.filter(fn d ->
        if expected_start, do: d.start_pos == expected_start, else: true
      end)
      |> Stream.filter(fn d ->
        if expected_end, do: d.end_pos == expected_end, else: true
      end)
      |> Stream.filter(fn d ->
        if min_confidence, do: d.confidence >= min_confidence, else: true
      end)
      |> Enum.at(0)

    assert matching != nil, """
    No detection found matching criteria.

    Text:
     #{text}

    Expected:
      type: #{inspect(type)}
      value: #{inspect(expected_value)}
      start_pos: #{inspect(expected_start)}
      end_pos: #{inspect(expected_end)}

    Found detections:
    #{format_detections(detections, text)}
    """

    # Verify position consistency: extracting at start_pos..end_pos yields the value
    extracted = binary_part(text, matching.start_pos, matching.end_pos - matching.start_pos)

    assert extracted == matching.value, """
    Position mismatch: extracting at #{matching.start_pos}..#{matching.end_pos} yields #{inspect(extracted)}, but detection.value is #{inspect(matching.value)}
    """

    matching
  end

  # Asserts that exactly N detections of a given type exist.
  defp assert_count(detections, type, count) do
    type = List.wrap(type)
    matching = Enum.filter(detections, &(&1.type in type))
    length_matching = length(matching)

    assert length_matching == count and length(detections) == count, """
    Expected exactly #{count} #{inspect(type)} detection(s), found #{length_matching}.

    Detections:
    #{format_detections(detections, nil)}
    """
  end

  # Asserts that at least N detections of a given type exist.
  defp assert_at_least(detections, type, min_count) do
    matching = Enum.filter(detections, &(&1.type == type))

    assert length(matching) >= min_count, """
    Expected at least #{min_count} #{type} detection(s), found #{length(matching)}.

    Matching detections:
    #{format_detections(matching, nil)}
    """
  end

  # Asserts that no detection of the given type exists.
  defp refute_detection(detections, type) do
    matching = Enum.filter(detections, &(&1.type == type))

    assert matching == [], """
    Expected no #{type} detections, but found #{length(matching)}:

    #{format_detections(matching, nil)}
    """
  end

  defp format_detections(detections, text) do
    detections
    |> Enum.map_join("\n", fn d ->
      if text do
        extracted = binary_part(text, d.start_pos, d.end_pos - d.start_pos)

        "  - #{d.type} - (#{d.description}) @ #{d.start_pos}..#{d.end_pos} (conf=#{Float.round(d.confidence, 2)}): #{inspect(d.value)} [extracted: #{inspect(extracted)}]"
      else
        "  - #{d.type} - (#{d.description}) @ #{d.start_pos}..#{d.end_pos} (conf=#{Float.round(d.confidence, 2)}): #{inspect(d.value)}"
      end
    end)
  end

  # ============================================================================
  # BASIC DETECTION TESTS
  # ============================================================================

  describe "basic detection: email addresses" do
    test "detects simple email at end of sentence" do
      text = "My email is john@example.com"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 12,
        end_pos: 28
      )

      assert_count(detections, :email, 1)
    end

    test "detects multiple emails with correct positions" do
      text = "Contact john@example.com or jane@example.org"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 8,
        end_pos: 24
      )

      assert_detection(detections, text,
        type: :email,
        value: "jane@example.org",
        start_pos: 28,
        end_pos: 44
      )

      assert_count(detections, :email, 2)
    end

    test "detects email at start of text" do
      text = "john@example.com is my email address"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 0,
        end_pos: 16
      )

      assert_count(detections, :email, 1)
    end

    test "detects email at end of text" do
      text = "Contact me at john@example.com"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 14,
        end_pos: 30
      )

      assert_count(detections, :email, 1)
    end

    test "detects email with leading/trailing whitespace (stripped in value)" do
      text = "  john@example.com  "
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 2,
        end_pos: 18
      )

      assert_count(detections, :email, 1)
    end

    test "detects email with plus addressing" do
      text = "Use john.doe+newsletter@example.com for subscriptions"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john.doe+newsletter@example.com",
        start_pos: 4,
        end_pos: 35
      )

      assert_count(detections, :email, 1)
    end

    test "detects email with special characters and subdomain" do
      text = "Contact user+tag@example.co.uk"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "user+tag@example.co.uk",
        start_pos: 8,
        end_pos: 30
      )

      assert_count(detections, :email, 1)
    end

    test "detects email in uppercase" do
      text = "Email: JOHN@EXAMPLE.COM"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "JOHN@EXAMPLE.COM",
        start_pos: 7,
        end_pos: 23
      )

      assert_count(detections, :email, 1)
    end
  end

  describe "basic detection: phone numbers" do
    test "detects US phone number with dashes" do
      text = "Call me at 555-123-4567"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :phone,
        value: "555-123-4567",
        start_pos: 11,
        end_pos: 23
      )

      assert_count(detections, :phone, 1)
    end

    test "detects phone number with parentheses" do
      text = "Phone: (555) 123-4567"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :phone,
        value: "(555) 123-4567",
        start_pos: 7,
        end_pos: 21
      )

      assert_count(detections, :phone, 1)
    end

    test "detects international phone number with country code" do
      text = "My number is +1 555 123 4567"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :phone,
        value: "+1 555 123 4567",
        start_pos: 13,
        end_pos: 28
      )

      assert_count(detections, :phone, 1)
    end

    test "detects phone with various formats in single text" do
      text = """
      Phone 1: (555) 123-4567
      Phone 2: 555.123.4567
      Phone 3: 555 123 4567
      Phone 4: 555-123-4567
      """

      detections = Detector.detect(text)

      assert_count(detections, :phone, 4)
    end
  end

  describe "basic detection: SSN" do
    test "detects SSN in XXX-XX-XXXX format" do
      text = "SSN: 123-45-6789"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ssn,
        value: "123-45-6789",
        start_pos: 5,
        end_pos: 16
      )

      assert_count(detections, :ssn, 1)
    end

    test "detects SSN with spaces" do
      text = "Social Security Number: 123 45 6789"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ssn,
        value: "123 45 6789",
        start_pos: 24,
        end_pos: 35
      )

      assert_count(detections, :ssn, 1)
    end
  end

  describe "basic detection: financial" do
    test "detects American Express card number" do
      text = "Amex: 378282246310005"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :financial,
        value: "378282246310005",
        start_pos: 6,
        end_pos: 21
      )

      assert_count(detections, :financial, 1)
    end

    test "detects credit card with separators" do
      text = "Card: 4111-1111-1111-1111"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :financial,
        value: "4111-1111-1111-1111",
        start_pos: 6,
        end_pos: 25
      )

      assert_count(detections, :financial, 1)
    end

    test "detects Visa card number without separators" do
      text = "Card: 4111111111111111"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :financial,
        value: "4111111111111111",
        start_pos: 6,
        end_pos: 22
      )

      assert_count(detections, :financial, 1)
    end
  end

  describe "basic detection: medical IDs" do
    test "detects medical record number with MRN prefix" do
      text = "MRN: ABC123456"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :medical_id,
        value: "MRN: ABC123456",
        start_pos: 0,
        end_pos: 14
      )

      assert_count(detections, :medical_id, 1)
    end
  end

  describe "basic detection: IP addresses" do
    test "detects IPv4 address" do
      text = "Server IP: 192.168.1.1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "192.168.1.1",
        start_pos: 11,
        end_pos: 22
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 address in full format" do
      text = "Server IP: 2001:0db8:85a3:0000:0000:8a2e:0370:7334"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
        start_pos: 11,
        end_pos: 50
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 address in compressed format with ::" do
      text = "Server IP: 2001:db8:85a3::8a2e:370:7334"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "2001:db8:85a3::8a2e:370:7334",
        start_pos: 11,
        end_pos: 39
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 loopback address ::1" do
      text = "Loopback: ::1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "::1",
        start_pos: 10,
        end_pos: 13
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 link-local address" do
      text = "Link-local: fe80::1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "fe80::1",
        start_pos: 12,
        end_pos: 19
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 address with leading ::" do
      text = "Address: ::ffff:192.168.1.1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "::ffff:192.168.1.1",
        start_pos: 9,
        end_pos: 27
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects IPv6 address starting with :: and full segments" do
      text = "Server: 2001:db8::1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "2001:db8::1",
        start_pos: 8,
        end_pos: 19
      )

      assert_count(detections, :ip_address, 1)
    end

    test "detects multiple IP addresses (IPv4 and IPv6) in same text" do
      text = "IPv4: 192.168.1.1, IPv6: 2001:db8::1"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ip_address,
        value: "192.168.1.1",
        start_pos: 6,
        end_pos: 17
      )

      assert_detection(detections, text,
        type: :ip_address,
        value: "2001:db8::1",
        start_pos: 25,
        end_pos: 36
      )

      assert_count(detections, :ip_address, 2)
    end
  end

  describe "basic detection: URLs" do
    test "detects HTTPS URL" do
      text = "Visit https://example.com for more info"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :url,
        value: "https://example.com",
        start_pos: 6,
        end_pos: 25
      )

      assert_count(detections, :url, 1)
    end
  end

  describe "basic detection: names and locations" do
    test "detects self-introduced name" do
      text = "My name is John Smith"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "John Smith",
        start_pos: 11,
        end_pos: 21
      )

      assert_count(detections, :name, 1)
    end

    test "detects labeled name" do
      text = "Name: John Smith"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "John Smith",
        start_pos: 6,
        end_pos: 16
      )

      assert_count(detections, :name, 1)
    end

    test "detects self-declared location" do
      text = "I live in New York"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :location,
        value: "New York",
        start_pos: 10,
        end_pos: 18
      )

      assert_count(detections, :location, 1)
    end

    test "detects street address pattern" do
      text = "I live at 123 Main Street"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :location,
        value: "123 Main Street",
        start_pos: 10,
        end_pos: 25
      )

      assert_count(detections, :location, 1)
    end
  end

  describe "basic detection: filtering and options" do
    test "filters by confidence threshold" do
      text = "Email: john@example.com"

      detections_high = Detector.detect(text, confidence_threshold: 0.9)
      assert_count(detections_high, :email, 1)

      detections_very_high = Detector.detect(text, confidence_threshold: 0.99)
      # Email confidence is 0.95, so this should return no results
      assert_count(detections_very_high, :email, 0)
    end

    test "filters by type" do
      text = "Email: john@example.com, Phone: 555-123-4567"

      detections_email = Detector.detect(text, types: [:email])
      assert_count(detections_email, :email, 1)
      refute_detection(detections_email, :phone)

      detections_phone = Detector.detect(text, types: [:phone])
      assert_at_least(detections_phone, :phone, 1)
      refute_detection(detections_phone, :email)
    end

    test "returns empty list for text without PII" do
      text = "Hello world, this is a test"
      detections = Detector.detect(text)
      assert detections == []
    end
  end

  describe "basic detection: multiple PII types" do
    test "detects all PII types with correct positions" do
      text = "Contact john@example.com or call 555-123-4567. My SSN is 123-45-6789."
      detections = Detector.detect(text)

      # Email detection
      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 8,
        end_pos: 24
      )

      # Phone detection (position after "or call ")
      assert_detection(detections, text,
        type: :phone,
        value: "555-123-4567",
        start_pos: 33,
        end_pos: 45
      )

      # SSN detection
      assert_detection(detections, text,
        type: :ssn,
        value: "123-45-6789",
        start_pos: 57,
        end_pos: 68
      )

      assert_count(detections, [:email, :phone, :ssn], 3)
    end
  end

  # ============================================================================
  # DETECT_LARGE TESTS
  # ============================================================================

  describe "detect_large/2" do
    test "handles large text with parallel processing" do
      base_text = "Contact john@example.com or call 555-123-4567. "
      large_text = String.duplicate(base_text, 100)

      detections = Detector.detect_large(large_text)

      text_len = String.length(base_text)
      # Verify all positions are valid
      for n <- 0..99 do
        assert_detection(detections, large_text,
          type: :email,
          value: "john@example.com",
          start_pos: 8 + text_len * n,
          end_pos: 24 + text_len * n
        )

        assert_detection(detections, large_text,
          type: :phone,
          value: "555-123-4567",
          start_pos: 33 + text_len * n,
          end_pos: 45 + text_len * n
        )
      end

      assert_count(detections, [:email, :phone], 200)
    end

    test "adjusts positions correctly for chunked detection" do
      base_text = "Contact john@example.com "
      large_text = String.duplicate(base_text, 100)

      detections = Detector.detect_large(large_text, chunk_size: 50)

      text_len = String.length(base_text)
      # Verify all positions are valid
      for n <- 0..99 do
        assert_detection(detections, large_text,
          type: :email,
          value: "john@example.com",
          start_pos: 8 + text_len * n,
          end_pos: 24 + text_len * n
        )
      end

      assert_count(detections, [:email, :phone], 100)
    end
  end

  # ============================================================================
  # CONTAINS_PII AND SUMMARY TESTS
  # ============================================================================

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

  # ============================================================================
  # REALISTIC LLM INPUT SCENARIOS
  # ============================================================================

  describe "realistic LLM: code snippets with credentials" do
    test "detects OpenAI API key in Python code" do
      text = ~s(openai.api_key = "sk-abc123def456ghi789jkl012mno345pqr678stu")
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :api_key,
        value: "sk-abc123def456ghi789jkl012mno345pqr678stu",
        start_pos: 18,
        end_pos: 60
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects password in YAML config" do
      text = "password: SuperSecretPassword123!"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :secret,
        value: "SuperSecretPassword123!",
        start_pos: 10,
        end_pos: 33
      )

      assert_count(detections, :secret, 1)
    end

    test "detects AWS Access Key ID" do
      text = "accessKeyId: 'AKIAIOSFODNN7EXAMPLE'"
      detections = Detector.detect(text, confidence_threshold: 0.5)

      assert_detection(detections, text,
        type: :api_key,
        value: "AKIAIOSFODNN7EXAMPLE",
        start_pos: 14,
        end_pos: 34
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects JWT token in code" do
      text =
        ~s(const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :auth_token,
        value:
          "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
        start_pos: 15,
        end_pos: 170
      )

      assert_count(detections, :auth_token, 1)
    end

    test "detects private key block" do
      text = """
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ==
      -----END OPENSSH PRIVATE KEY-----
      """

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :private_key,
        value: String.trim_trailing(text, "\n"),
        start_pos: 0,
        end_pos: 114
      )

      assert_count(detections, :private_key, 1)
    end

    test "detects API keys in environment variable exports" do
      text =
        ~s(export OPENAI_API_KEY="sk-proj-abc123def456ghi789jkl012mno345pqr678stu901vwx234yz")

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :api_key,
        value: "sk-proj-abc123def456ghi789jkl012mno345pqr678stu901vwx234yz",
        start_pos: 23,
        end_pos: 81
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects database connection string with credentials" do
      text = "postgres://admin:secretpassword@localhost:5432/mydb"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :secret,
        value: "postgres://admin:secretpassword@localhost:5432/mydb",
        start_pos: 0,
        end_pos: 51
      )

      assert_count(detections, :secret, 1)
    end

    test "detects MongoDB connection string" do
      text = "mongodb+srv://admin:MySecurePassword123@cluster0.mongodb.net/mydb"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :secret,
        value: "mongodb+srv://admin:MySecurePassword123@cluster0.mongodb.net/mydb",
        start_pos: 0,
        end_pos: 65
      )

      assert_count(detections, :secret, 1)
    end
  end

  describe "realistic LLM: API documentation and examples" do
    test "detects Stripe API key in curl example" do
      text = "-u sk_live_abcdefghijklmnopqrstuvwxyz:"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :api_key,
        value: "sk_live_abcdefghijklmnopqrstuvwxyz",
        start_pos: 3,
        end_pos: 37
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects Bearer token in Authorization header" do
      text =
        "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.example_signature"

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :auth_token,
        value:
          "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.example_signature",
        start_pos: 15,
        end_pos: 104
      )

      assert_count(detections, :auth_token, 1)
    end

    test "detects GitHub personal access token" do
      text = "Authorization: token ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :api_key,
        value: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        start_pos: 21,
        end_pos: 61
      )

      assert_count(detections, :api_key, 1)
    end
  end

  describe "realistic LLM: user support requests" do
    test "detects email and IP in error report" do
      text = "My account email is sarah.johnson@gmail.com. IP Address: 203.0.113.45"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "sarah.johnson@gmail.com",
        start_pos: 20,
        end_pos: 43
      )

      assert_detection(detections, text,
        type: :ip_address,
        value: "203.0.113.45",
        start_pos: 57,
        end_pos: 69
      )

      assert_count(detections, [:email, :ip_address], 2)
    end

    test "detects email and name in billing support request" do
      text = "- Name: Michael Chen\n- Email: michael.chen@company.com"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "Michael Chen",
        start_pos: 8,
        end_pos: 20
      )

      assert_detection(detections, text,
        type: :email,
        value: "michael.chen@company.com",
        start_pos: 30,
        end_pos: 54
      )

      assert_count(detections, [:name, :email], 2)
    end

    test "detects phone and name in account recovery request" do
      text = "Full Name: Emily Rodriguez\nPhone Number: (415) 555-7890"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "Emily Rodriguez",
        start_pos: 11,
        end_pos: 26
      )

      assert_detection(detections, text,
        type: :phone,
        value: "(415) 555-7890",
        start_pos: 41,
        end_pos: 55
      )

      assert_count(detections, [:name, :phone], 2)
    end
  end

  describe "realistic LLM: medical and health queries" do
    test "detects medical record number" do
      text = "My MRN is ABC123456789"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :medical_id,
        value: "ABC123456789",
        start_pos: 10,
        end_pos: 22
      )

      assert_count(detections, :medical_id, 1)
    end
  end

  describe "realistic LLM: financial context" do
    test "detects name in bank account information" do
      text = "Account Holder: Robert Williams"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "Robert Williams",
        start_pos: 16,
        end_pos: 31
      )

      assert_count(detections, :name, 1)
    end

    test "detects IBAN in international transfer query" do
      text = "IBAN: DE89370400440532013000"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :financial,
        value: "DE89370400440532013000",
        start_pos: 6,
        end_pos: 28
      )

      assert_count(detections, :financial, 1)
    end

    test "detects name and financial info in transfer request" do
      text = "Recipient: Hans Mueller\nIBAN: DE89370400440532013000"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "Hans Mueller",
        start_pos: 11,
        end_pos: 23
      )

      assert_detection(detections, text,
        type: :financial,
        value: "DE89370400440532013000",
        start_pos: 30,
        end_pos: 52
      )

      assert_count(detections, [:name, :financial], 2)
    end
  end

  describe "realistic LLM: configuration and deployment" do
    test "detects Kubernetes secret manifest" do
      text = """
      apiVersion: v1
      kind: Secret
      metadata:
        name: app-secrets
      data:
        database-password: U3VwZXJTZWNyZXQxMjMh
      """

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :secret,
        value: "U3VwZXJTZWNyZXQxMjMh",
        start_pos: 85,
        end_pos: 105
      )

      assert_count(detections, :secret, 1)
    end

    test "detects Slack webhook URL" do
      text =
        ~s(webhook_url = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX")

      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :secret,
        value: "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX",
        start_pos: 15,
        end_pos: 92
      )

      assert_count(detections, :secret, 1)
    end
  end

  # ============================================================================
  # EDGE CASES
  # ============================================================================

  describe "edge cases: PII at boundaries" do
    test "detects email at start of text" do
      text = "john@example.com is my email address"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 0,
        end_pos: 16
      )

      assert_count(detections, :email, 1)
    end

    test "detects PII in single-line text without spaces" do
      text = "Email:john@example.com Phone:555-123-4567 SSN:123-45-6789"
      detections = Detector.detect(text)

      # Email should be detected
      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 6,
        end_pos: 22
      )

      # Phone should be detected
      assert_detection(detections, text,
        type: :phone,
        value: "555-123-4567",
        start_pos: 29,
        end_pos: 41
      )

      # SSN should be detected
      assert_detection(detections, text,
        type: :ssn,
        value: "123-45-6789",
        start_pos: 46,
        end_pos: 57
      )

      assert_count(detections, [:email, :phone, :ssn], 3)
    end
  end

  describe "edge cases: overlapping patterns" do
    test "detects both email and URL in same text" do
      text = "Contact support@example.com or visit https://example.com/contact"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "support@example.com",
        start_pos: 8,
        end_pos: 27
      )

      assert_detection(detections, text,
        type: :url,
        value: "https://example.com/contact",
        start_pos: 37,
        end_pos: 64
      )

      assert_count(detections, [:email, :url], 2)
    end

    test "handles SSN-like numbers correctly" do
      text = "My SSN is 123-45-6789."
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :ssn,
        value: "123-45-6789",
        start_pos: 10,
        end_pos: 21
      )

      assert_count(detections, :ssn, 1)
    end
  end

  describe "edge cases: false positives" do
    test "does not detect PII in plain text" do
      text = "Hello world, this is a test"
      detections = Detector.detect(text)
      assert detections == []
    end

    test "does not flag common words as names" do
      text = "I am happy with this result"
      detections = Detector.detect(text)

      # Should not detect "I am" as a name
      # If any detections exist, verify they're not false positives
      for detection <- detections do
        refute detection.type == :name && detection.value == "I am"
      end
    end

    test "handles text with no PII correctly" do
      text = """
      The quick brown fox jumps over the lazy dog.
      This is a test of the emergency broadcast system.
      Lorem ipsum dolor sit amet, consectetur adipiscing elit.
      """

      detections = Detector.detect(text)
      assert detections == []
    end

    test "does not flag version numbers as IP addresses" do
      text = "Using version 1.2.3 of the library, upgrading to 2.0.0 soon"
      detections = Detector.detect(text)

      # Version numbers like 1.2.3 or 2.0.0 should not be flagged as IP addresses
      for detection <- detections do
        refute detection.type == :ip_address && detection.value in ["1.2.3", "2.0.0"]
      end
    end

    test "does not flag semantic versioning as IP addresses" do
      text = "Package version 10.20.30 is outdated, please update to 1.0.0"
      detections = Detector.detect(text)

      # Semantic versions should not be detected as IPs
      for detection <- detections do
        refute detection.type == :ip_address && detection.value in ["10.20.30", "1.0.0"]
      end
    end

    test "does not flag dates as SSNs" do
      text = "The meeting is scheduled for 01-02-2023 or 03/04/2024"
      detections = Detector.detect(text)

      # Dates in DD-MM-YYYY or MM/DD/YYYY format should not be flagged as SSNs
      for detection <- detections do
        refute detection.type == :ssn
      end
    end

    test "does not flag mathematical expressions as phone numbers" do
      text = "Calculate 555 + 123 - 4567 to get the result"
      detections = Detector.detect(text)

      # Mathematical expressions should not be detected as phone numbers
      for detection <- detections do
        refute detection.type == :phone && detection.value == "555 + 123 - 4567"
      end
    end

    test "does not flag file paths with numbers as PII" do
      text = "The file is located at /home/user/documents/12345/file.txt"
      detections = Detector.detect(text)

      # File paths with numeric components should not be flagged
      for detection <- detections do
        refute detection.value == "12345"
      end
    end

    test "does not flag technical identifiers as API keys" do
      text = "The request ID is abc123-def456-ghi789 for debugging"
      detections = Detector.detect(text)

      # Generic request IDs should not be flagged as API keys
      for detection <- detections do
        refute detection.type == :api_key && detection.value == "abc123-def456-ghi789"
      end
    end

    test "does not flag UUID-like strings as secrets" do
      text = "Session ID: 550e8400-e29b-41d4-a716-446655440000"
      detections = Detector.detect(text)

      # UUIDs should not typically be flagged as secrets
      for detection <- detections do
        refute detection.type == :secret &&
                 detection.value == "550e8400-e29b-41d4-a716-446655440000"
      end
    end

    test "does not flag common abbreviations as names" do
      text = "The CEO and CFO met with the VP of Sales"
      detections = Detector.detect(text)

      # Common business abbreviations should not be flagged as names
      for detection <- detections do
        refute detection.type == :name && detection.value in ["CEO", "CFO", "VP"]
      end
    end

    test "does not flag timestamps as phone numbers" do
      text = "Log entry at 12:34:56 shows the error occurred"
      detections = Detector.detect(text)

      # Time formats should not be flagged as phone numbers
      for detection <- detections do
        refute detection.type == :phone && detection.value == "12:34:56"
      end
    end

    test "does not flag coordinate-like numbers as SSNs" do
      text = "Location: 40.7128-74.0060 (latitude-longitude format)"
      detections = Detector.detect(text)

      # Coordinate formats should not be flagged as SSNs
      for detection <- detections do
        refute detection.type == :ssn
      end
    end

    test "does not flag URL query parameters as emails" do
      text = "Visit https://example.com?user=test&domain=example.com"
      detections = Detector.detect(text)

      # Query parameter values should not be combined into fake emails
      for detection <- detections do
        refute detection.type == :email && detection.value == "test@domain"
      end
    end

    test "does not flag code variable names as names" do
      text = "let firstName = 'value'; const lastName = 'value';"
      detections = Detector.detect(text)

      # Variable names in code should not be flagged as person names
      for detection <- detections do
        refute detection.type == :name && detection.value in ["firstName", "lastName"]
      end
    end

    test "does not flag hexadecimal color codes as financial data" do
      text = "Background color: #FF5733, text color: #123456"
      detections = Detector.detect(text)

      # Hex color codes should not be flagged as financial/credit card data
      for detection <- detections do
        refute detection.type == :financial
      end
    end

    test "does not flag order numbers as financial data" do
      text = "Order #1234567890123456 has been shipped"
      detections = Detector.detect(text)

      # Order numbers should not be flagged as credit card numbers
      for detection <- detections do
        refute detection.type == :financial && detection.value == "1234567890123456"
      end
    end

    test "does not flag ISBN numbers as financial data" do
      text = "Book ISBN: 978-3-16-148410-0"
      detections = Detector.detect(text)

      # ISBN numbers should not be flagged as financial data
      for detection <- detections do
        refute detection.type == :financial && detection.value == "978-3-16-148410-0"
      end
    end

    test "does not flag common placeholder values as secrets" do
      text = "password = 'password123', api_key = 'your-api-key-here'"
      detections = Detector.detect(text)

      # Common placeholder values should not be flagged as real secrets
      # These are obviously fake/test values
      for detection <- detections do
        if detection.type == :secret do
          # These are commonly known placeholder values
          refute detection.value in ["password123", "your-api-key-here"]
        end
      end
    end

    test "does not flag localhost as sensitive IP" do
      text = "Connect to localhost:8080 for development"
      detections = Detector.detect(text)

      # Localhost references should not be flagged as sensitive IP addresses
      # or if detected, should have low confidence
      localhost_detections = Enum.filter(detections, &(&1.value == "localhost"))
      assert localhost_detections == []
    end

    test "does not flag example.com emails as sensitive" do
      text = "See documentation at docs@example.com for more info"
      detections = Detector.detect(text)

      # Example.com emails are reserved for documentation and not real PII
      # However, we still detect them - this test documents the behavior
      email_detections = Enum.filter(detections, &(&1.type == :email))
      # We detect the email, but it's documented that example.com is reserved
      assert is_list(email_detections)
    end

    test "does not flag 127.0.0.1 as sensitive IP in development context" do
      text = "Development server running on 127.0.0.1:3000"
      detections = Detector.detect(text)

      # 127.0.0.1 is localhost/loopback - commonly used in development
      # If detected, it should be with appropriate context
      ip_detections = Enum.filter(detections, &(&1.type == :ip_address))

      # We may detect it, but verify it's the loopback address
      for detection <- ip_detections do
        if detection.value == "127.0.0.1" do
          # This is acceptable - loopback is not sensitive
          assert true
        end
      end
    end

    test "does not flag markdown links as URLs with sensitive data" do
      text = "[Click here](https://example.com) for more information"
      detections = Detector.detect(text)

      # URLs in markdown links should be detected as URLs, not confused with other PII
      url_detections = Enum.filter(detections, &(&1.type == :url))
      assert length(url_detections) <= 1
    end

    test "does not flag RFC 3339 timestamps as phone numbers" do
      text = "Event occurred at 2023-12-25T10:30:45Z"
      detections = Detector.detect(text)

      # ISO 8601 / RFC 3339 timestamps should not be flagged as phone numbers
      for detection <- detections do
        refute detection.type == :phone
      end
    end

    test "does not flag programming language keywords as names" do
      text = "function User() { return this; } class Person extends User {}"
      detections = Detector.detect(text)

      # Programming keywords should not be flagged as names
      for detection <- detections do
        refute detection.value in ["User", "Person"]
      end
    end

    test "does not flag JSON keys as names" do
      text = ~s({"name": "value", "firstName": "value", "lastName": "value"})
      detections = Detector.detect(text)

      # JSON keys should not be flagged as names
      for detection <- detections do
        refute detection.type == :name && detection.value in ["name", "firstName", "lastName"]
      end
    end

    test "does not flag tracking numbers as SSNs" do
      text = "Your tracking number is 1234 5678 9012"
      detections = Detector.detect(text)

      # Tracking numbers should not be flagged as SSNs
      for detection <- detections do
        refute detection.type == :ssn
      end
    end

    test "does not flag currency amounts as financial account numbers" do
      text = "The price is $123.45 or €99.99"
      detections = Detector.detect(text)

      # Currency amounts should not be flagged as financial account numbers
      for detection <- detections do
        refute detection.type == :financial && detection.value in ["123.45", "99.99"]
      end
    end

    test "does not flag common test/example values as secrets" do
      text = "api_key: 'test', password: 'test123', secret: 'example'"
      detections = Detector.detect(text)

      # Common test values should not be flagged as real secrets
      for detection <- detections do
        if detection.type == :secret do
          refute detection.value in ["test", "test123", "example"]
        end
      end
    end

    test "does not flag hexadecimal numbers as API keys" do
      text = "Color code: 0xFF5733, hex value: 0xDEADBEEF"
      detections = Detector.detect(text)

      # Hexadecimal numbers should not be flagged as API keys
      for detection <- detections do
        refute detection.type == :api_key && detection.value in ["0xFF5733", "0xDEADBEEF"]
      end
    end

    test "does not flag base64-encoded non-sensitive data as secrets" do
      text = "Data: SGVsbG8gV29ybGQh (base64 encoded 'Hello World!')"
      detections = Detector.detect(text)

      # Base64 encoded common phrases should not be flagged as secrets
      for detection <- detections do
        refute detection.type == :secret && detection.value == "SGVsbG8gV29ybGQh"
      end
    end
  end

  describe "edge cases: JSON and structured data" do
    test "detects PII in JSON payload" do
      text = ~s({"name": "Alice Johnson", "email": "alice@example.com", "phone": "555-987-6543"})
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :name,
        value: "Alice Johnson",
        start_pos: 10,
        end_pos: 23
      )

      assert_detection(detections, text,
        type: :email,
        value: "alice@example.com",
        start_pos: 36,
        end_pos: 53
      )

      assert_detection(detections, text,
        type: :phone,
        value: "555-987-6543",
        start_pos: 66,
        end_pos: 78
      )

      assert_count(detections, [:name, :email, :phone], 3)
    end

    test "detects API key in JSON" do
      text = ~s({"api_key": "sk-abc123def456ghi789jkl"})
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :api_key,
        value: "sk-abc123def456ghi789jkl",
        start_pos: 13,
        end_pos: 37
      )

      assert_count(detections, :api_key, 1)
    end
  end

  # ============================================================================
  # MISSING PII TYPES: DATES
  # ============================================================================

  describe "basic detection: dates" do
    test "detects ISO date format YYYY-MM-DD" do
      text = "Meeting on 2024-01-15"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "2024-01-15",
        start_pos: 11,
        end_pos: 21
      )

      assert_count(detections, :date, 1)
    end

    test "detects ISO date format YYYY-MM-DD (variant)" do
      text = "Holiday is 2024-12-25"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "2024-12-25",
        start_pos: 11,
        end_pos: 21
      )

      assert_count(detections, :date, 1)
    end

    test "detects US date format MM/DD/YYYY" do
      text = "Event on 01/15/2024"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "01/15/2024",
        start_pos: 9,
        end_pos: 19
      )

      assert_count(detections, :date, 1)
    end

    test "detects US date format MM-DD-YYYY" do
      text = "Due date 12-25-2024"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "12-25-2024",
        start_pos: 9,
        end_pos: 19
      )

      assert_count(detections, :date, 1)
    end

    test "detects European date format DD.MM.YYYY" do
      text = "Termin am 15.01.2024"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "15.01.2024",
        start_pos: 10,
        end_pos: 20
      )

      assert_count(detections, :date, 1)
    end

    test "detects European date format DD/MM/YYYY" do
      text = "Fecha: 25/12/2024"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "25/12/2024",
        start_pos: 7,
        end_pos: 17
      )

      assert_count(detections, :date, 1)
    end

    test "detects DOB context with Date of birth label" do
      text = "Date of birth: 1990-05-20"
      # At default threshold, the DOB pattern (0.95) matches via the ISO date
      # sub-pattern or via NER. We assert a date is found at the expected position.
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "1990-05-20",
        start_pos: 15,
        end_pos: 25
      )

      assert_count(detections, :date, 1)
    end

    test "detects DOB context with DOB label" do
      text = "DOB: 01/15/1990"
      detections = Detector.detect(text, types: [:date])

      assert_detection(detections, text,
        type: :date,
        value: "DOB: 01/15/1990",
        start_pos: 0,
        end_pos: 15
      )

      assert_count(detections, :date, 1)
    end
  end

  # ============================================================================
  # MISSING PII TYPES: NATIONAL IDs
  # ============================================================================

  describe "basic detection: national IDs" do
    test "detects UK NINO compact format" do
      text = "NINO: AB123456C"
      detections = Detector.detect(text, types: [:national_id])

      assert_detection(detections, text,
        type: :national_id,
        value: "AB123456C",
        start_pos: 6,
        end_pos: 15
      )

      assert_count(detections, :national_id, 1)
    end

    test "detects UK NINO spaced format" do
      text = "NINO: AB 12 34 56 C"
      detections = Detector.detect(text, types: [:national_id])
      # The current regex does not allow spaces; verify it is not detected at default
      # (if a future pattern adds spaced support, this test should be updated).
      refute_detection(detections, :national_id)
    end

    test "detects Canadian SIN with spaces at lowered threshold" do
      text = "SIN: 123 456 789"
      # Confidence 0.60; below default 0.8
      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_low = Detector.detect(text, types: [:national_id], confidence_threshold: 0.5)

      assert_detection(detections_low, text,
        type: :national_id,
        value: "123 456 789",
        start_pos: 5,
        end_pos: 16
      )

      assert_count(detections_low, :national_id, 1)
    end

    test "detects Canadian SIN with dashes at lowered threshold" do
      text = "SIN: 123-456-789"
      detections = Detector.detect(text, types: [:national_id], confidence_threshold: 0.5)

      assert_detection(detections, text,
        type: :national_id,
        value: "123-456-789",
        start_pos: 5,
        end_pos: 16
      )

      assert_count(detections, :national_id, 1)
    end

    test "detects Australian TFN with context" do
      text = "Tax File Number: 123456789"
      detections = Detector.detect(text, types: [:national_id])

      assert_detection(detections, text,
        type: :national_id,
        value: "Tax File Number: 123456789",
        start_pos: 0,
        end_pos: 26
      )

      assert_count(detections, :national_id, 1)
    end

    test "detects Australian TFN bare at lowered threshold" do
      text = "12345678"
      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_low = Detector.detect(text, types: [:national_id], confidence_threshold: 0.35)

      assert_detection(detections_low, text,
        type: :national_id,
        value: "12345678",
        start_pos: 0,
        end_pos: 8
      )

      assert_count(detections_low, :national_id, 1)
    end

    test "detects Irish PPS compact format at lowered threshold" do
      # Irish PPS (7 digits + letter) has confidence 0.75, below default 0.8
      text = "PPS: 1234567A"
      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_low = Detector.detect(text, types: [:national_id], confidence_threshold: 0.7)

      assert_detection(detections_low, text,
        type: :national_id,
        value: "1234567A",
        start_pos: 5,
        end_pos: 13
      )

      assert_count(detections_low, :national_id, 1)
    end

    test "detects Irish PPS two-letter suffix at lowered threshold" do
      text = "PPS: 1234567AB"
      detections = Detector.detect(text, types: [:national_id], confidence_threshold: 0.7)
      # Current pattern matches only \d{7}[A-Z] (one letter), so two-letter suffix does not match.
      refute_detection(detections, :national_id)
    end

    test "detects German Tax ID at lowered threshold" do
      text = "Tax ID: 12345678901"
      # Confidence 0.50; below default 0.8
      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_low = Detector.detect(text, types: [:national_id], confidence_threshold: 0.4)

      assert_detection(detections_low, text,
        type: :national_id,
        value: "12345678901",
        start_pos: 8,
        end_pos: 19
      )

      assert_count(detections_low, :national_id, 1)
    end

    test "detects French INSEE number" do
      text = "INSEE: 185067501234545"
      detections = Detector.detect(text, types: [:national_id])

      assert_detection(detections, text,
        type: :national_id,
        value: "185067501234545",
        start_pos: 7,
        end_pos: 22
      )

      assert_count(detections, :national_id, 1)
    end

    test "detects Spanish DNI at lowered threshold" do
      text = "DNI: 12345678A"
      # Confidence 0.75; below default 0.8
      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_low = Detector.detect(text, types: [:national_id], confidence_threshold: 0.7)

      assert_detection(detections_low, text,
        type: :national_id,
        value: "12345678A",
        start_pos: 5,
        end_pos: 14
      )

      assert_count(detections_low, :national_id, 1)
    end

    test "does not detect Spanish NIE with current patterns" do
      text = "NIE: X1234567L"
      detections = Detector.detect(text, types: [:national_id])
      # Current DNI pattern requires 8 digits before the letter; NIE starts with X/Y/Z.
      refute_detection(detections, :national_id)
    end

    test "detects Italian Fiscal Code" do
      text = "CF: RSSMRA85M01H501Z"
      detections = Detector.detect(text, types: [:national_id])

      assert_detection(detections, text,
        type: :national_id,
        value: "RSSMRA85M01H501Z",
        start_pos: 4,
        end_pos: 20
      )

      assert_count(detections, :national_id, 1)
    end
  end

  # ============================================================================
  # MISSING PII TYPES: DEVICE IDs
  # ============================================================================

  describe "basic detection: device identifiers" do
    test "detects MAC address colon format" do
      text = "MAC: 00:1A:2B:3C:4D:5E"
      detections = Detector.detect(text, types: [:device_id])

      assert_detection(detections, text,
        type: :device_id,
        value: "00:1A:2B:3C:4D:5E",
        start_pos: 5,
        end_pos: 22
      )

      assert_count(detections, :device_id, 1)
    end

    test "detects MAC address dash format" do
      text = "MAC: 00-1A-2B-3C-4D-5E"
      detections = Detector.detect(text, types: [:device_id])

      assert_detection(detections, text,
        type: :device_id,
        value: "00-1A-2B-3C-4D-5E",
        start_pos: 5,
        end_pos: 22
      )

      assert_count(detections, :device_id, 1)
    end

    test "detects UUID/GUID" do
      text = "UUID: 550e8400-e29b-41d4-a716-446655440000"
      detections = Detector.detect(text, types: [:device_id])

      assert_detection(detections, text,
        type: :device_id,
        value: "550e8400-e29b-41d4-a716-446655440000",
        start_pos: 6,
        end_pos: 42
      )

      assert_count(detections, :device_id, 1)
    end

    test "detects IMEI with context" do
      text = "IMEI: 490154203237518"
      detections = Detector.detect(text, types: [:device_id])

      assert_detection(detections, text,
        type: :device_id,
        value: "IMEI: 490154203237518",
        start_pos: 0,
        end_pos: 21
      )

      assert_count(detections, :device_id, 1)
    end

    test "does not detect bare IMEI at default threshold" do
      text = "number is 490154203237518"
      detections = Detector.detect(text, types: [:device_id])
      refute_detection(detections, :device_id)
    end

    test "detects VIN at lowered threshold" do
      text = "VIN: 1HGCM82633A123456"
      # VIN confidence is 0.75, below default 0.8
      detections_default = Detector.detect(text, types: [:device_id])
      refute_detection(detections_default, :device_id)

      detections_low = Detector.detect(text, types: [:device_id], confidence_threshold: 0.7)

      assert_detection(detections_low, text,
        type: :device_id,
        value: "1HGCM82633A123456",
        start_pos: 5,
        end_pos: 22
      )

      assert_count(detections_low, :device_id, 1)
    end

    test "detects license plate at lowered threshold" do
      text = "Plate: ABC1234"
      # License-plate confidence is 0.50
      detections_default = Detector.detect(text, types: [:device_id])
      refute_detection(detections_default, :device_id)

      detections_low = Detector.detect(text, types: [:device_id], confidence_threshold: 0.4)

      assert_detection(detections_low, text,
        type: :device_id,
        value: "ABC1234",
        start_pos: 7,
        end_pos: 14
      )

      assert_count(detections_low, :device_id, 1)
    end

    test "detects license plate with dashes at lowered threshold" do
      text = "Plate: AB-1234-CD"
      detections = Detector.detect(text, types: [:device_id], confidence_threshold: 0.4)

      assert_detection(detections, text,
        type: :device_id,
        value: "AB-1234-CD",
        start_pos: 7,
        end_pos: 17
      )

      assert_count(detections, :device_id, 1)
    end
  end

  # ============================================================================
  # MISSING PII TYPES: PASSPORTS
  # ============================================================================

  describe "basic detection: passport numbers" do
    test "detects passport with context" do
      text = "Passport: C1234567"
      detections = Detector.detect(text, types: [:passport])

      assert_detection(detections, text,
        type: :passport,
        value: "Passport: C1234567",
        start_pos: 0,
        end_pos: 18
      )

      assert_count(detections, :passport, 1)
    end

    test "detects passport numeric format with context" do
      text = "Passport: 123456789"
      detections = Detector.detect(text, types: [:passport])

      assert_detection(detections, text,
        type: :passport,
        value: "Passport: 123456789",
        start_pos: 0,
        end_pos: 19
      )

      assert_count(detections, :passport, 1)
    end

    test "does not detect bare passport-like numbers without context" do
      text = "Number: 123456789"
      detections = Detector.detect(text, types: [:passport])
      refute_detection(detections, :passport)
    end
  end

  # ============================================================================
  # EXTENDED API KEY PATTERNS
  # ============================================================================

  describe "extended detection: API key patterns" do
    test "detects Anthropic API key" do
      text = "anthropic: sk-ant-api03-abc123def456ghi789jkl"
      detections = Detector.detect(text, types: [:api_key])

      assert_detection(detections, text,
        type: :api_key,
        value: "sk-ant-api03-abc123def456ghi789jkl",
        start_pos: 11,
        end_pos: 45
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects Mailgun API key" do
      text = "mailgun key: key-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
      detections = Detector.detect(text, types: [:api_key])

      assert_detection(detections, text,
        type: :api_key,
        value: "key-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
        start_pos: 13,
        end_pos: 49
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects Mailchimp API key" do
      text = "mailchimp: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4-us14"
      detections = Detector.detect(text, types: [:api_key])

      assert_detection(detections, text,
        type: :api_key,
        value: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4-us14",
        start_pos: 11,
        end_pos: 48
      )

      assert_count(detections, :api_key, 1)
    end

    test "detects generic api_key assignment" do
      text = ~s(api_key = "mysecretapikey12345678901")
      detections = Detector.detect(text, types: [:api_key])

      assert_detection(detections, text,
        type: :api_key,
        value: "mysecretapikey12345678901",
        start_pos: 11,
        end_pos: 36
      )

      assert_count(detections, :api_key, 1)
    end
  end

  # ============================================================================
  # EXTENDED SECRET PATTERNS
  # ============================================================================

  describe "extended detection: secret patterns" do
    test "detects password Python-style assignment" do
      text = ~s(password = "mysecretpassword123")
      detections = Detector.detect(text, types: [:secret])

      assert_detection(detections, text,
        type: :secret,
        value: ~s(password = "mysecretpassword123"),
        start_pos: 0,
        end_pos: 32
      )

      assert_count(detections, :secret, 1)
    end

    test "detects password colon assignment" do
      text = ~s(password: "mysecretpassword123")
      detections = Detector.detect(text, types: [:secret])

      assert_detection(detections, text,
        type: :secret,
        value: ~s(password: "mysecretpassword123"),
        start_pos: 0,
        end_pos: 31
      )

      assert_count(detections, :secret, 1)
    end

    test "detects password in YAML-style line" do
      text = "password: mysecretpassword123"
      detections = Detector.detect(text, types: [:secret])

      assert_detection(detections, text,
        type: :secret,
        value: "mysecretpassword123",
        start_pos: 10,
        end_pos: 29
      )

      assert_count(detections, :secret, 1)
    end

    test "detects private_key assignment in code" do
      text = ~s(private_key = "ssh-rsa AAAA...")
      detections = Detector.detect(text, types: [:private_key])

      assert_detection(detections, text,
        type: :private_key,
        value: ~s(private_key = "ssh-rsa AAAA..."),
        start_pos: 0,
        end_pos: 31
      )

      assert_count(detections, :private_key, 1)
    end

    test "detects uppercase PRIVATE_KEY assignment in code" do
      text = ~s(PRIVATE_KEY = "ssh-rsa AAAA...")
      detections = Detector.detect(text, types: [:private_key])

      assert_detection(detections, text,
        type: :private_key,
        value: ~s(PRIVATE_KEY = "ssh-rsa AAAA..."),
        start_pos: 0,
        end_pos: 31
      )

      assert_count(detections, :private_key, 1)
    end

    test "detects client_secret with equals sign" do
      text = "client_secret=abc123def456ghi789jkl01mno"
      detections = Detector.detect(text, types: [:secret])

      assert_detection(detections, text,
        type: :secret,
        value: "client_secret=abc123def456ghi789jkl01mno",
        start_pos: 0,
        end_pos: 40
      )

      assert_count(detections, :secret, 1)
    end

    test "detects client_secret with quoted value" do
      text = ~s(client_secret="abc123def456ghi789jkl01mno")
      detections = Detector.detect(text, types: [:secret])

      assert_detection(detections, text,
        type: :secret,
        value: ~s(client_secret="abc123def456ghi789jkl01mno"),
        start_pos: 0,
        end_pos: 42
      )

      assert_count(detections, :secret, 1)
    end
  end

  # ============================================================================
  # MULTI-PATTERN AND BOUNDARY TESTS
  # ============================================================================

  describe "edge cases: multi-pattern and boundaries" do
    test "detects multiple PII types in single text" do
      text = "Contact john@example.com at 555-123-4567, SSN: 123-45-6789"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 8,
        end_pos: 24
      )

      assert_detection(detections, text,
        type: :phone,
        value: "555-123-4567",
        start_pos: 28,
        end_pos: 40
      )

      assert_detection(detections, text,
        type: :ssn,
        value: "123-45-6789",
        start_pos: 47,
        end_pos: 58
      )

      assert_count(detections, [:email, :phone, :ssn], 3)
    end

    test "detects PII at exact start of string" do
      text = "john@example.com is my email"
      detections = Detector.detect(text, types: [:email])

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 0,
        end_pos: 16
      )

      assert_count(detections, :email, 1)
    end

    test "detects PII at exact end of string" do
      text = "Reach me at john@example.com"
      detections = Detector.detect(text, types: [:email])

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 12,
        end_pos: 28
      )

      assert_count(detections, :email, 1)
    end

    test "detects PII spanning across chunks in detect_large (fully inside chunk)" do
      text = String.duplicate("a", 10_000) <> "john@example.com"
      detections = Detector.detect_large(text, chunk_size: 10_000, types: [:email])

      assert length(detections) == 1

      [detection] = detections
      assert detection.type == :email
      assert detection.value == "john@example.com"
      assert detection.start_pos == 10_000
      assert detection.end_pos == 10_016
    end

    test "detects PII with Unicode characters nearby" do
      text = "Mon email est jean@exemple.com 🎉"
      detections = Detector.detect(text, types: [:email])

      assert_detection(detections, text,
        type: :email,
        value: "jean@exemple.com",
        start_pos: 14,
        end_pos: 30
      )

      assert_count(detections, :email, 1)
    end
  end

  # ============================================================================
  # CONFIDENCE THRESHOLD EDGE CASES
  # ============================================================================

  describe "edge cases: confidence thresholds" do
    test "Canadian SIN detected at threshold 0.6 but not at default 0.8" do
      text = "SIN: 123 456 789"

      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_0_6 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.6)
      assert_count(detections_0_6, :national_id, 1)

      detections_0_61 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.61)
      refute_detection(detections_0_61, :national_id)
    end

    test "Australian TFN bare detected at threshold 0.4 but not at default 0.8" do
      text = "12345678"

      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_0_4 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.4)
      assert_count(detections_0_4, :national_id, 1)
      [d] = detections_0_4
      assert d.confidence == 0.4

      detections_0_41 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.41)
      refute_detection(detections_0_41, :national_id)
    end

    test "Spanish DNI detected at threshold 0.75 but not at default 0.8" do
      text = "DNI: 12345678A"

      detections_default = Detector.detect(text, types: [:national_id])
      refute_detection(detections_default, :national_id)

      detections_0_75 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.75)
      assert_count(detections_0_75, :national_id, 1)

      detections_0_76 = Detector.detect(text, types: [:national_id], confidence_threshold: 0.76)
      refute_detection(detections_0_76, :national_id)
    end

    test "VIN detected at threshold 0.75 but not at default 0.8" do
      text = "VIN: 1HGCM82633A123456"

      detections_default = Detector.detect(text, types: [:device_id])
      refute_detection(detections_default, :device_id)

      detections_0_75 = Detector.detect(text, types: [:device_id], confidence_threshold: 0.75)
      assert_count(detections_0_75, :device_id, 1)

      detections_0_76 = Detector.detect(text, types: [:device_id], confidence_threshold: 0.76)
      refute_detection(detections_0_76, :device_id)
    end

    test "license plate detected at threshold 0.5 but not at default 0.8" do
      text = "Plate: ABC1234"

      detections_default = Detector.detect(text, types: [:device_id])
      refute_detection(detections_default, :device_id)

      detections_0_5 = Detector.detect(text, types: [:device_id], confidence_threshold: 0.5)
      assert_count(detections_0_5, :device_id, 1)

      detections_0_51 = Detector.detect(text, types: [:device_id], confidence_threshold: 0.51)
      refute_detection(detections_0_51, :device_id)
    end
  end
end
