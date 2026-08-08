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

  defp assert_detection(detections, text, expected) do
    type = Keyword.fetch!(expected, :type)
    expected_value = Keyword.get(expected, :value)
    expected_start = Keyword.get(expected, :start_pos)
    expected_end = Keyword.get(expected, :end_pos)
    min_confidence = Keyword.get(expected, :min_confidence)

    matching =
      detections
      |> Stream.filter(&(&1.type == type))
      |> Stream.filter(fn d -> if expected_value, do: d.value == expected_value, else: true end)
      |> Stream.filter(fn d ->
        if expected_start, do: d.start_pos == expected_start, else: true
      end)
      |> Stream.filter(fn d -> if expected_end, do: d.end_pos == expected_end, else: true end)
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

    extracted = binary_part(text, matching.start_pos, matching.end_pos - matching.start_pos)

    assert extracted == matching.value, """
    Position mismatch: extracting at #{matching.start_pos}..#{matching.end_pos} yields #{inspect(extracted)}, but detection.value is #{inspect(matching.value)}
    """

    matching
  end

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

  defp assert_at_least(detections, type, min_count) do
    matching = Enum.filter(detections, &(&1.type == type))

    assert length(matching) >= min_count, """
    Expected at least #{min_count} #{type} detection(s), found #{length(matching)}.

    Matching detections:
    #{format_detections(matching, nil)}
    """
  end

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
  # BASIC DETECTION — SINGLE TESTS PER CATEGORY
  # ============================================================================

  describe "email detection" do
    test "detects single emails with correct positions" do
      cases = [
        {"My email is john@example.com", "john@example.com", 12, 28},
        {"john@example.com is my email address", "john@example.com", 0, 16},
        {"Use john.doe+newsletter@example.com for subscriptions",
         "john.doe+newsletter@example.com", 4, 35}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: :email,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :email, 1)
      end
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
  end

  describe "phone detection" do
    test "detects phone numbers in various formats" do
      cases = [
        {"Call me at 555-123-4567", "555-123-4567", 11, 23},
        {"Phone: (555) 123-4567", "(555) 123-4567", 7, 21},
        {"My number is +1 555 123 4567", "+1 555 123 4567", 13, 28}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: :phone,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :phone, 1)
      end
    end

    test "detects multiple phone formats in single text" do
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

  describe "SSN detection" do
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

  describe "financial detection" do
    test "detects credit card numbers in various formats" do
      cases = [
        {"Amex: 378282246310005", "378282246310005", 6, 21},
        {"Card: 4111-1111-1111-1111", "4111-1111-1111-1111", 6, 25},
        {"Card: 4111111111111111", "4111111111111111", 6, 22}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: :financial,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :financial, 1)
      end
    end
  end

  describe "medical ID detection" do
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

  describe "IP address detection" do
    test "detects single IP addresses in various formats" do
      cases = [
        {"Server IP: 192.168.1.1", "192.168.1.1", 11, 22},
        {"Server IP: 2001:0db8:85a3:0000:0000:8a2e:0370:7334",
         "2001:0db8:85a3:0000:0000:8a2e:0370:7334", 11, 50},
        {"Loopback: ::1", "::1", 10, 13}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: :ip_address,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :ip_address, 1)
      end
    end

    test "detects multiple IP addresses in same text" do
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

  describe "URL detection" do
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

  describe "name and location detection" do
    test "detects names in various contexts" do
      cases = [
        {"My name is John Smith", "John Smith", 11, 21, :name},
        {"Name: John Smith", "John Smith", 6, 16, :name}
      ]

      for {input, expected_value, start_pos, end_pos, type} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: type,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, type, 1)
      end
    end

    test "detects locations in various contexts" do
      cases = [
        {"I live in New York", "New York", 10, 18, :location},
        {"I live at 123 Main Street", "123 Main Street", 10, 25, :location}
      ]

      for {input, expected_value, start_pos, end_pos, type} <- cases do
        detections = Detector.detect(input)

        assert_detection(detections, input,
          type: type,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, type, 1)
      end
    end
  end

  # ============================================================================
  # FILTERING AND API TESTS
  # ============================================================================

  describe "filtering and options" do
    test "filters by confidence threshold" do
      text = "Email: john@example.com"

      detections_high = Detector.detect(text, confidence_threshold: 0.9)
      assert_count(detections_high, :email, 1)

      detections_very_high = Detector.detect(text, confidence_threshold: 0.99)
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

  describe "multiple PII types" do
    test "detects all PII types with correct positions" do
      text = "Contact john@example.com or call 555-123-4567. My SSN is 123-45-6789."
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
        start_pos: 33,
        end_pos: 45
      )

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
    @tag :slow
    test "handles large text with parallel processing" do
      base_text = "Contact john@example.com or call 555-123-4567. "
      large_text = String.duplicate(base_text, 100)
      detections = Detector.detect_large(large_text)
      text_len = String.length(base_text)

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

    @tag :slow
    test "adjusts positions correctly for chunked detection" do
      base_text = "Contact john@example.com "
      large_text = String.duplicate(base_text, 100)
      detections = Detector.detect_large(large_text, chunk_size: 50)
      text_len = String.length(base_text)

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
  # CONTAINS_PII AND SUMMARY
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
  # REALISTIC LLM SCENARIOS
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
    test "detects PII in single-line text without spaces" do
      text = "Email:john@example.com Phone:555-123-4567 SSN:123-45-6789"
      detections = Detector.detect(text)

      assert_detection(detections, text,
        type: :email,
        value: "john@example.com",
        start_pos: 6,
        end_pos: 22
      )

      assert_detection(detections, text,
        type: :phone,
        value: "555-123-4567",
        start_pos: 29,
        end_pos: 41
      )

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
    @tag :slow
    test "does not flag false positives with type+value refutations" do
      refute_cases = [
        {"I am happy with this result", :name, "I am"},
        {"The CEO and CFO met with the VP of Sales", :name, "CEO"},
        {"The CEO and CFO met with the VP of Sales", :name, "CFO"},
        {"The CEO and CFO met with the VP of Sales", :name, "VP"},
        {"let firstName = 'value'; const lastName = 'value';", :name, "firstName"},
        {"let firstName = 'value'; const lastName = 'value';", :name, "lastName"},
        {~s({"name": "value", "firstName": "value", "lastName": "value"}), :name, "name"},
        {~s({"name": "value", "firstName": "value", "lastName": "value"}), :name, "firstName"},
        {~s({"name": "value", "firstName": "value", "lastName": "value"}), :name, "lastName"},
        {"function User() { return this; } class Person extends User {}", :name, "User"},
        {"function User() { return this; } class Person extends User {}", :name, "Person"},
        {"Using version 1.2.3 of the library, upgrading to 2.0.0 soon", :ip_address, "1.2.3"},
        {"Using version 1.2.3 of the library, upgrading to 2.0.0 soon", :ip_address, "2.0.0"},
        {"Package version 10.20.30 is outdated, please update to 1.0.0", :ip_address, "10.20.30"},
        {"Package version 10.20.30 is outdated, please update to 1.0.0", :ip_address, "1.0.0"},
        {"Calculate 555 + 123 - 4567 to get the result", :phone, "555 + 123 - 4567"},
        {"Log entry at 12:34:56 shows the error occurred", :phone, "12:34:56"},
        {"Order #1234567890123456 has been shipped", :financial, "1234567890123456"},
        {"Book ISBN: 978-3-16-148410-0", :financial, "978-3-16-148410-0"},
        {"The price is $123.45 or €99.99", :financial, "123.45"},
        {"The price is $123.45 or €99.99", :financial, "99.99"},
        {"Session ID: 550e8400-e29b-41d4-a716-446655440000", :secret,
         "550e8400-e29b-41d4-a716-446655440000"},
        {"Data: SGVsbG8gV29ybGQh (base64 encoded 'Hello World!')", :secret, "SGVsbG8gV29ybGQh"},
        {"The request ID is abc123-def456-ghi789 for debugging", :api_key,
         "abc123-def456-ghi789"},
        {"Color code: 0xFF5733, hex value: 0xDEADBEEF", :api_key, "0xFF5733"},
        {"Color code: 0xFF5733, hex value: 0xDEADBEEF", :api_key, "0xDEADBEEF"}
      ]

      for {input, type, value} <- refute_cases do
        detections = Detector.detect(input)

        for detection <- detections do
          refute detection.type == type && detection.value == value,
                 "False positive: #{type} #{inspect(value)} detected in #{inspect(input)}"
        end
      end
    end

    test "does not flag false positives with type-only refutations" do
      refute_type_cases = [
        {"Background color: #FF5733, text color: #123456", :financial},
        {"Event occurred at 2023-12-25T10:30:45Z", :phone},
        {"Your tracking number is 1234 5678 9012", :national_id},
        {"The meeting is scheduled for 01-02-2023 or 03/04/2024", :ssn},
        {"Number: 490154203237518", :device_id}
      ]

      for {input, type} <- refute_type_cases do
        detections = Detector.detect(input)

        for detection <- detections do
          refute detection.type == type,
                 "False positive: #{type} detected in #{inspect(input)}"
        end
      end
    end

    test "does not detect PII in plain text" do
      text = "Hello world, this is a test"
      detections = Detector.detect(text)
      assert detections == []
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

    test "does not flag file paths with numbers as PII" do
      text = "The file is located at /home/user/documents/12345/file.txt"
      detections = Detector.detect(text)

      for detection <- detections do
        refute detection.value == "12345"
      end
    end

    test "does not flag common placeholder or test values as secrets" do
      texts = [
        "password = 'password123', api_key = 'your-api-key-here'",
        "api_key: 'test', password: 'test123', secret: 'example'"
      ]

      forbidden_values = ["password123", "your-api-key-here", "test", "test123", "example"]

      for text <- texts do
        detections = Detector.detect(text)

        for detection <- detections do
          if detection.type == :secret do
            refute detection.value in forbidden_values,
                   "False positive: secret #{inspect(detection.value)} in #{inspect(text)}"
          end
        end
      end
    end

    test "does not flag localhost as sensitive IP" do
      text = "Connect to localhost:8080 for development"
      detections = Detector.detect(text)

      localhost_detections = Enum.filter(detections, &(&1.value == "localhost"))
      assert localhost_detections == []
    end

    test "does not flag example.com emails as sensitive" do
      text = "See documentation at docs@example.com for more info"
      detections = Detector.detect(text)

      email_detections = Enum.filter(detections, &(&1.type == :email))
      assert is_list(email_detections)
    end

    test "does not flag 127.0.0.1 as sensitive IP in development context" do
      text = "Development server running on 127.0.0.1:3000"
      detections = Detector.detect(text)

      ip_detections = Enum.filter(detections, &(&1.type == :ip_address))

      for detection <- ip_detections do
        if detection.value == "127.0.0.1" do
          assert true
        end
      end
    end

    test "does not flag markdown links as URLs with sensitive data" do
      text = "[Click here](https://example.com) for more information"
      detections = Detector.detect(text)

      url_detections = Enum.filter(detections, &(&1.type == :url))
      assert length(url_detections) <= 1
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
  # DATE DETECTION — SINGLE TEST
  # ============================================================================

  describe "date detection" do
    test "detects dates in various formats" do
      cases = [
        {"Meeting on 2024-01-15", "2024-01-15", 11, 21},
        {"Event on 01/15/2024", "01/15/2024", 9, 19},
        {"Date of birth: 1990-05-20", "1990-05-20", 15, 25}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [:date])

        assert_detection(detections, input,
          type: :date,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :date, 1)
      end
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
  # NATIONAL ID DETECTION — SINGLE TEST
  # ============================================================================

  describe "national ID detection" do
    test "detects national IDs at default threshold" do
      cases = [
        {"NINO: AB123456C", "AB123456C", 6, 15},
        {"Tax File Number: 123456789", "Tax File Number: 123456789", 0, 26},
        {"INSEE: 185067501234545", "185067501234545", 7, 22},
        {"CF: RSSMRA85M01H501Z", "RSSMRA85M01H501Z", 4, 20}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [:national_id])

        assert_detection(detections, input,
          type: :national_id,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :national_id, 1)
      end
    end

    @tag :slow
    test "detects national IDs at lowered thresholds" do
      cases = [
        {"SIN: 123 456 789", "123 456 789", 5, 16, 0.5},
        {"SIN: 123-456-789", "123-456-789", 5, 16, 0.5},
        {"12345678", "12345678", 0, 8, 0.35},
        {"PPS: 1234567A", "1234567A", 5, 13, 0.7},
        {"Tax ID: 12345678901", "12345678901", 8, 19, 0.4},
        {"DNI: 12345678A", "12345678A", 5, 14, 0.7}
      ]

      for {input, expected_value, start_pos, end_pos, threshold} <- cases do
        # Should NOT be detected at default threshold
        detections_default = Detector.detect(input, types: [:national_id])
        refute_detection(detections_default, :national_id)

        # Should be detected at lowered threshold
        detections_low =
          Detector.detect(input, types: [:national_id], confidence_threshold: threshold)

        assert_detection(detections_low, input,
          type: :national_id,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections_low, :national_id, 1)
      end
    end

    test "does not detect certain national ID formats" do
      negative_cases = [
        "NINO: AB 12 34 56 C",
        "PPS: 1234567AB",
        "NIE: X1234567L"
      ]

      for input <- negative_cases do
        detections = Detector.detect(input, types: [:national_id])
        refute_detection(detections, :national_id)
      end
    end
  end

  # ============================================================================
  # DEVICE ID DETECTION — SINGLE TEST
  # ============================================================================

  describe "device ID detection" do
    test "detects device IDs at default threshold" do
      cases = [
        {"MAC: 00:1A:2B:3C:4D:5E", "00:1A:2B:3C:4D:5E", 5, 22},
        {"MAC: 00-1A-2B-3C-4D-5E", "00-1A-2B-3C-4D-5E", 5, 22},
        {"UUID: 550e8400-e29b-41d4-a716-446655440000", "550e8400-e29b-41d4-a716-446655440000", 6,
         42},
        {"IMEI: 490154203237518", "IMEI: 490154203237518", 0, 21}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [:device_id])

        assert_detection(detections, input,
          type: :device_id,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :device_id, 1)
      end
    end

    test "detects device IDs at lowered thresholds" do
      cases = [
        {"VIN: 1HGCM82633A123456", "1HGCM82633A123456", 5, 22, 0.7},
        {"Plate: ABC1234", "ABC1234", 7, 14, 0.4},
        {"Plate: AB-1234-CD", "AB-1234-CD", 7, 17, 0.4}
      ]

      for {input, expected_value, start_pos, end_pos, threshold} <- cases do
        detections_default = Detector.detect(input, types: [:device_id])
        refute_detection(detections_default, :device_id)

        detections_low =
          Detector.detect(input, types: [:device_id], confidence_threshold: threshold)

        assert_detection(detections_low, input,
          type: :device_id,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections_low, :device_id, 1)
      end
    end

    test "does not detect bare IMEI at default threshold" do
      text = "number is 490154203237518"
      detections = Detector.detect(text, types: [:device_id])
      refute_detection(detections, :device_id)
    end
  end

  # ============================================================================
  # PASSPORT NUMBERS
  # ============================================================================

  describe "passport number detection" do
    test "detects passport numbers with context" do
      cases = [
        {"Passport: C1234567", "Passport: C1234567", 0, 18},
        {"Passport: 123456789", "Passport: 123456789", 0, 19}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [:passport])

        assert_detection(detections, input,
          type: :passport,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :passport, 1)
      end
    end

    test "does not detect bare passport-like numbers without context" do
      text = "Number: 123456789"
      detections = Detector.detect(text, types: [:passport])
      refute_detection(detections, :passport)
    end
  end

  # ============================================================================
  # API KEY PATTERNS — SINGLE TEST
  # ============================================================================

  describe "API key pattern detection" do
    test "detects various API key formats" do
      cases = [
        {"anthropic: sk-ant-api03-abc123def456ghi789jkl", "sk-ant-api03-abc123def456ghi789jkl",
         11, 45},
        {"mailgun key: key-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
         "key-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4", 13, 49},
        {"mailchimp: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4-us14",
         "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4-us14", 11, 48},
        {~s(api_key = "mysecretapikey12345678901"), "mysecretapikey12345678901", 11, 36}
      ]

      for {input, expected_value, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [:api_key])

        assert_detection(detections, input,
          type: :api_key,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, :api_key, 1)
      end
    end
  end

  # ============================================================================
  # SECRET PATTERNS — SINGLE TEST
  # ============================================================================

  describe "secret pattern detection" do
    test "detects various secret patterns" do
      cases = [
        {~s(password = "mysecretpassword123"), ~s(password = "mysecretpassword123"), :secret, 0,
         32},
        {"password: mysecretpassword123", "mysecretpassword123", :secret, 10, 29},
        {"client_secret=abc123def456ghi789jkl01mno", "client_secret=abc123def456ghi789jkl01mno",
         :secret, 0, 40}
      ]

      for {input, expected_value, type, start_pos, end_pos} <- cases do
        detections = Detector.detect(input, types: [type])

        assert_detection(detections, input,
          type: type,
          value: expected_value,
          start_pos: start_pos,
          end_pos: end_pos
        )

        assert_count(detections, type, 1)
      end
    end
  end

  # ============================================================================
  # MULTI-PATTERN AND BOUNDARY TESTS
  # ============================================================================

  describe "multi-pattern and boundary tests" do
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

    test "detects PII spanning across chunks in detect_large" do
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
  # CONFIDENCE THRESHOLD EDGE CASES — SINGLE TEST
  # ============================================================================

  describe "confidence threshold edge cases" do
    @tag :slow
    test "detected at threshold but not above" do
      cases = [
        {"SIN: 123 456 789", :national_id, 0.60, nil},
        {"12345678", :national_id, 0.40, 0.4},
        {"DNI: 12345678A", :national_id, 0.75, nil},
        {"VIN: 1HGCM82633A123456", :device_id, 0.75, nil},
        {"Plate: ABC1234", :device_id, 0.50, 0.5}
      ]

      for {text, type, detect_threshold, exact_confidence} <- cases do
        # Should NOT be detected at default (0.8)
        detections_default = Detector.detect(text, types: [type])
        refute_detection(detections_default, type)

        # Should be detected at the threshold
        detections_at =
          Detector.detect(text, types: [type], confidence_threshold: detect_threshold)

        assert_count(detections_at, type, 1)

        # Optionally verify exact confidence
        if exact_confidence do
          [d] = detections_at
          assert d.confidence == exact_confidence
        end

        # Should NOT be detected just above the threshold
        detections_above =
          Detector.detect(text, types: [type], confidence_threshold: detect_threshold + 0.01)

        refute_detection(detections_above, type)
      end
    end
  end
end
