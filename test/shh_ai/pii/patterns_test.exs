defmodule ShhAi.PII.PatternsTest do
  use ExUnit.Case, async: true

  alias ShhAi.PII.Patterns

  setup_all do
    # Ensure patterns are loaded
    Patterns.load_into_persistent_term()
    :ok
  end

  describe "all/0" do
    test "returns list of compiled patterns" do
      patterns = Patterns.all()

      assert is_list(patterns)
      assert patterns != []

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
      assert email_patterns != []
    end

    test "includes phone pattern" do
      patterns = Patterns.all()

      phone_patterns = Enum.filter(patterns, &(&1.type == :phone))
      assert phone_patterns != []
    end

    test "includes ssn pattern" do
      patterns = Patterns.all()

      ssn_patterns = Enum.filter(patterns, &(&1.type == :ssn))
      assert ssn_patterns != []
    end

    test "includes financial pattern" do
      patterns = Patterns.all()

      financial_patterns = Enum.filter(patterns, &(&1.type == :financial))
      assert financial_patterns != []
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
      assert email_patterns != []

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

  describe "phone patterns" do
    test "US phone pattern does not match inside longer digit runs" do
      us = regex_for(:phone, "US phone number")

      refute Regex.match?(us, "4111111111111111")
      refute Regex.match?(us, "490154203237518")
      refute Regex.match?(us, "4111-1111-1111-1111")

      assert Regex.match?(us, "555-123-4567")
      assert Regex.match?(us, "(555) 123-4567")
      assert Regex.match?(us, "555.123.4567")
    end

    test "international phone pattern does not match inside longer digit runs" do
      intl = regex_for(:phone, "International phone number")

      refute Regex.match?(intl, "490154203237518")

      assert Regex.match?(intl, "+1 555 123 4567")
    end
  end

  describe "ssn patterns" do
    test "SSN pattern does not match ZIP+4 codes" do
      ssn = regex_for(:ssn, "US Social Security Number")

      refute Regex.match?(ssn, "74293-1609")

      assert Regex.match?(ssn, "123-45-6789")
      assert Regex.match?(ssn, "123 45 6789")
    end

    test "driver's licence is a national ID, not an SSN" do
      refute Enum.any?(Patterns.for_type(:ssn), &(&1.description == "Driver's license number"))

      assert Enum.any?(
               Patterns.for_type(:national_id),
               &(&1.description == "Driver's license number")
             )
    end
  end

  describe "ip_address patterns" do
    test "IPv6 patterns ignore Elixir `::` syntax but still match addresses" do
      ip = Patterns.for_type(:ip_address) |> Enum.map(& &1.pattern)
      matches? = fn text -> Enum.any?(ip, &Regex.match?(&1, text)) end

      refute matches?.("@spec run(term()) :: :ok | {:error, term()}")
      refute matches?.("<<size::binary-size(4), rest::binary>>")
      refute matches?.("@type t :: %__MODULE__{field: integer()}")

      for address <- ["2001:db8::1", "fe80::1", "::1", "2001:db8::", "::ffff:192.168.1.1"] do
        assert matches?.("connect to #{address} now"), "expected match for #{address}"
      end
    end
  end

  describe "financial patterns" do
    test "IBAN pattern matches real IBAN structure" do
      iban = regex_for(:financial, "IBAN")

      assert Regex.match?(iban, "GB82WEST12345698765432")
      assert Regex.match?(iban, "FI4053006671108009")
      assert Regex.match?(iban, "TR530066375008008370050483")
    end

    test "account number pattern fires on labelled account numbers" do
      financial = Patterns.for_type(:financial) |> Enum.map(& &1.pattern)

      assert Enum.any?(financial, &Regex.match?(&1, "account number 63652332"))
      assert Enum.any?(financial, &Regex.match?(&1, "account 71573733"))
    end
  end

  describe "device identifier patterns" do
    test "detects the dashed IMEI format" do
      device = Patterns.for_type(:device_id) |> Enum.map(& &1.pattern)

      assert Enum.any?(device, &Regex.match?(&1, "IMEI: 06-184755-866851-3"))
      assert Enum.any?(device, &Regex.match?(&1, "device bearing 06-184755-866851-3."))
    end
  end

  describe "PIN and card verification patterns" do
    test "detects a PIN only next to a context word" do
      secrets = Patterns.for_type(:secret) |> Enum.map(& &1.pattern)

      assert Enum.any?(secrets, &Regex.match?(&1, "PIN - 8824"))
      assert Enum.any?(secrets, &Regex.match?(&1, "associated PIN 1644"))

      refute Enum.any?(secrets, &Regex.match?(&1, "the number 8824 was seen"))
    end

    test "detects a CVV only next to a context word" do
      secrets = Patterns.for_type(:secret) |> Enum.map(& &1.pattern)

      assert Enum.any?(secrets, &Regex.match?(&1, "the CVV is 531"))
      assert Enum.any?(secrets, &Regex.match?(&1, "card verification value (936)"))
      assert Enum.any?(secrets, &Regex.match?(&1, "security code being 383"))

      refute Enum.any?(secrets, &Regex.match?(&1, "the total is 531"))
    end
  end

  describe "checksum-validated patterns" do
    test "detects a bare Luhn-valid card but rejects a same-shape number failing Luhn" do
      assert detects?(:financial, "4111111111111111")
      refute detects?(:financial, "4111111111111112")
    end

    test "detects a bare and a spaced IBAN but rejects one failing mod-97" do
      assert detects?(:financial, "GB82WEST12345698765432")
      assert detects?(:financial, "GB82 WEST 1234 5698 7654 32")
      refute detects?(:financial, "GB82WEST12345698765433")
    end

    test "detects a bare SSN but rejects numbers breaking the structural rules" do
      assert detects?(:ssn, "123456789")
      assert detects?(:ssn, "123-45-6789")

      # area 000 / 666 / 9xx, group 00, serial 0000
      refute detects?(:ssn, "000456789")
      refute detects?(:ssn, "666456789")
      refute detects?(:ssn, "900456789")
      refute detects?(:ssn, "123006789")
      refute detects?(:ssn, "123450000")
    end

    test "detects a bare Luhn-valid IMEI but rejects one failing Luhn" do
      assert detects?(:device_id, "490154203237518")
      refute detects?(:device_id, "490154203237519")
    end

    test "validate/2 accepts entries with no validator" do
      entry = Patterns.for_type(:email) |> hd()
      assert Patterns.validate(entry, "anything")
    end
  end

  # Mirrors the detector: a match counts only when the pattern entry's
  # validator accepts the matched value.
  defp detects?(type, text) do
    type
    |> Patterns.for_type()
    |> Enum.any?(fn entry ->
      entry.pattern
      |> Regex.scan(text, return: :index)
      |> Enum.any?(fn
        [{start, length}] -> Patterns.validate(entry, binary_part(text, start, length))
        [{_s, _l} | [{cs, cl} | _]] -> Patterns.validate(entry, binary_part(text, cs, cl))
      end)
    end)
  end

  defp regex_for(type, description) do
    type
    |> Patterns.for_type()
    |> Enum.find(&(&1.description == description))
    |> Map.fetch!(:pattern)
  end
end
