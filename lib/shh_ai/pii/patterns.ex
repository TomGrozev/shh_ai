defmodule ShhAi.PII.Patterns do
  @moduledoc """
  Regex patterns and detection rules for PII identification.
  All patterns are compiled at load time and stored in :persistent_term
  for zero-cost reads during request processing.
  """

  @type pii_type ::
          :name
          | :location
          | :email
          | :phone
          | :ssn
          | :credit_card
          | :date
          | :medical_id
          | :ip_address
          | :url

  @type pattern_entry :: %{
          type: pii_type(),
          pattern: Regex.t(),
          confidence: float(),
          description: String.t()
        }

  @type patterns :: [pattern_entry()]

  @doc """
  Returns all compiled PII patterns.
  Patterns are loaded from :persistent_term for fast access.
  """
  @spec all() :: patterns()
  def all do
    :persistent_term.get({__MODULE__, :patterns})
  end

  @doc """
  Returns patterns for a specific PII type.
  """
  @spec for_type(pii_type()) :: [pattern_entry()]
  def for_type(type) do
    all()
    |> Enum.filter(fn entry -> entry.type == type end)
  end

  @doc """
  Loads all patterns into :persistent_term.
  Should be called once at application startup.
  """
  @spec load_into_persistent_term() :: :ok
  def load_into_persistent_term do
    patterns = compile_patterns()
    :persistent_term.put({__MODULE__, :patterns}, patterns)
    :ok
  end

  # Private functions

  defp compile_patterns do
    [
      # Email addresses - high confidence
      %{
        type: :email,
        pattern: ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
        confidence: 0.95,
        description: "Email address"
      },

      # Phone numbers - various formats
      # US format: (XXX) XXX-XXXX or XXX-XXX-XXXX or XXX.XXX.XXXX
      %{
        type: :phone,
        pattern: ~r/\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/,
        confidence: 0.85,
        description: "US phone number"
      },

      # International phone: +XX XXX XXX XXXX or similar
      %{
        type: :phone,
        pattern: ~r/\+\d{1,3}[-.\s]?\d{1,4}[-.\s]?\d{1,4}[-.\s]?\d{1,9}/,
        confidence: 0.80,
        description: "International phone number"
      },

      # SSN - US Social Security Number: XXX-XX-XXXX or XXX XX XXXX
      %{
        type: :ssn,
        pattern: ~r/\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b/,
        confidence: 0.90,
        description: "US Social Security Number"
      },

      # Credit Card numbers - various formats
      # Visa: starts with 4, 13-16 digits
      %{
        type: :credit_card,
        pattern: ~r/\b4\d{12}(\d{3})?\b/,
        confidence: 0.85,
        description: "Visa card number"
      },

      # MasterCard: starts with 51-55 or 2221-2720, 16 digits
      %{
        type: :credit_card,
        pattern: ~r/\b(?:5[1-5]\d{2}|222[1-9]|22[3-9]\d|2[3-6]\d{2}|27[01]\d|2720)\d{12}\b/,
        confidence: 0.85,
        description: "MasterCard number"
      },

      # Amex: starts with 34 or 37, 15 digits
      %{
        type: :credit_card,
        pattern: ~r/\b3[47]\d{13}\b/,
        confidence: 0.90,
        description: "American Express card number"
      },

      # Generic credit card with spaces or dashes
      %{
        type: :credit_card,
        pattern: ~r/\b(?:\d{4}[-\s]){3}\d{4}\b/,
        confidence: 0.75,
        description: "Credit card number with separators"
      },

      # Dates - various formats
      # ISO format: YYYY-MM-DD
      %{
        type: :date,
        pattern: ~r/\b\d{4}[-\/]\d{1,2}[-\/]\d{1,2}\b/,
        confidence: 0.70,
        description: "ISO date format"
      },

      # US format: MM/DD/YYYY or MM-DD-YYYY
      %{
        type: :date,
        pattern: ~r/\b\d{1,2}[-\/]\d{1,2}[-\/]\d{4}\b/,
        confidence: 0.70,
        description: "US date format"
      },

      # European format: DD/MM/YYYY or DD.MM.YYYY
      %{
        type: :date,
        pattern: ~r/\b\d{1,2}[\/.]\d{1,2}[\/.]\d{4}\b/,
        confidence: 0.65,
        description: "European date format"
      },

      # Birth date specific patterns
      %{
        type: :date,
        pattern: ~r/(?:DOB|Date of Birth|Born|Birthday)[:\s]*\d{1,2}[-\/.]\d{1,2}[-\/.]\d{2,4}/i,
        confidence: 0.95,
        description: "Date of birth"
      },

      # Medical Record Numbers
      # MRN format: various, but often alphanumeric
      %{
        type: :medical_id,
        pattern: ~r/\b(?:MRN|Medical Record|Patient ID)[:\s]*[A-Z0-9-]{5,20}\b/i,
        confidence: 0.85,
        description: "Medical record number"
      },

      # Health insurance ID
      %{
        type: :medical_id,
        pattern: ~r/\b(?:Insurance ID|Policy Number|Member ID)[:\s]*[A-Z0-9-]{5,20}\b/i,
        confidence: 0.80,
        description: "Health insurance ID"
      },

      # IP Addresses
      # IPv4
      %{
        type: :ip_address,
        pattern: ~r/\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b/,
        confidence: 0.90,
        description: "IPv4 address"
      },

      # IPv6 (simplified pattern)
      %{
        type: :ip_address,
        pattern: ~r/\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b/,
        confidence: 0.90,
        description: "IPv6 address"
      },

      # URLs (may contain PII)
      %{
        type: :url,
        pattern: ~r/https?:\/\/[^\s<>"]+|www\.[^\s<>"]+/,
        confidence: 0.80,
        description: "URL"
      },

      # US Driver's License - varies by state, generic pattern
      %{
        type: :ssn,
        pattern: ~r/\b(?:DL|Driver'?s?\s*Lic(?:ense)?)[:\s]*[A-Z]\d{7,12}\b/i,
        confidence: 0.75,
        description: "Driver's license number"
      },

      # Passport numbers - various formats
      %{
        type: :ssn,
        pattern: ~r/\b(?:Passport|PP)[:\s]*[A-Z0-9]{6,12}\b/i,
        confidence: 0.80,
        description: "Passport number"
      },

      # Bank Account Numbers
      # US routing number (9 digits)
      %{
        type: :credit_card,
        pattern: ~r/\b(?:Routing|RTN|ABA)[:\s]*\d{9}\b/i,
        confidence: 0.80,
        description: "Bank routing number"
      },

      # Account number (variable length)
      %{
        type: :credit_card,
        pattern: ~r/\b(?:Account|Acct)[:\s#]*\d{6,17}\b/i,
        confidence: 0.70,
        description: "Bank account number"
      },

      # Address patterns
      # US Street address
      %{
        type: :location,
        pattern:
          ~r/\b\d+\s+[A-Za-z0-9\s]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way|Court|Ct|Place|Pl|Circle|Cir)\.?\b/i,
        confidence: 0.80,
        description: "Street address"
      },

      # ZIP codes (US)
      %{
        type: :location,
        pattern: ~r/\b\d{5}(?:-\d{4})?\b/,
        confidence: 0.60,
        description: "US ZIP code"
      },

      # Person names - more contextual patterns
      # "My name is X" or "I am X"
      %{
        type: :name,
        pattern: ~r/(?:My name is|I am|I'm|Call me)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)/,
        confidence: 0.85,
        description: "Self-introduced name"
      },

      # "Name: X" pattern
      %{
        type: :name,
        pattern: ~r/(?:Name|Full Name)[:\s]+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)/,
        confidence: 0.85,
        description: "Labeled name"
      },

      # Full name patterns (First Last)
      %{
        type: :name,
        pattern: ~r/\b[A-Z][a-z]+\s+[A-Z][a-z]+\b/,
        confidence: 0.50,
        description: "Potential full name"
      },

      # Location context patterns
      # "I live in X" or "I'm from X"
      %{
        type: :location,
        pattern:
          ~r/(?:I live in|I'm from|I am from|My location is|I am in|I'm in)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)/,
        confidence: 0.85,
        description: "Self-declared location"
      },

      # City, State pattern
      %{
        type: :location,
        pattern: ~r/\b[A-Z][a-z]+,\s*[A-Z]{2}\b/,
        confidence: 0.70,
        description: "City, State"
      }
    ]
  end
end
