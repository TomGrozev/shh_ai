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
          | :financial
          | :date
          | :medical_id
          | :ip_address
          | :url
          | :api_key
          | :secret
          | :auth_token
          | :private_key
          | :national_id
          | :device_id

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
        type: :financial,
        pattern: ~r/\b4\d{12}(\d{3})?\b/,
        confidence: 0.85,
        description: "Visa card number"
      },

      # MasterCard: starts with 51-55 or 2221-2720, 16 digits
      %{
        type: :financial,
        pattern: ~r/\b(?:5[1-5]\d{2}|222[1-9]|22[3-9]\d|2[3-6]\d{2}|27[01]\d|2720)\d{12}\b/,
        confidence: 0.85,
        description: "MasterCard number"
      },

      # Amex: starts with 34 or 37, 15 digits
      %{
        type: :financial,
        pattern: ~r/\b3[47]\d{13}\b/,
        confidence: 0.90,
        description: "American Express card number"
      },

      # Generic credit card with spaces or dashes
      %{
        type: :financial,
        pattern: ~r/\b(?:\d{4}[-\s]){3}\d{4}\b/,
        confidence: 0.80,
        description: "Credit card number with separators"
      },

      # Dates - various formats
      # ISO format: YYYY-MM-DD
      %{
        type: :date,
        pattern: ~r/\b\d{4}[-\/]\d{1,2}[-\/]\d{1,2}\b/,
        confidence: 0.80,
        description: "ISO date format"
      },

      # US format: MM/DD/YYYY or MM-DD-YYYY
      %{
        type: :date,
        pattern: ~r/\b\d{1,2}[-\/]\d{1,2}[-\/]\d{4}\b/,
        confidence: 0.80,
        description: "US date format"
      },

      # European format: DD/MM/YYYY or DD.MM.YYYY
      %{
        type: :date,
        pattern: ~r/\b\d{1,2}[\/.]\d{1,2}[\/.]\d{4}\b/,
        confidence: 0.80,
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

      # US Driver's License - varies by state, generic pattern
      %{
        type: :ssn,
        pattern: ~r/\b(?:DL|Driver'?s?\s*Lic(?:ense)?)[:\s]*[A-Z]\d{7,12}\b/i,
        confidence: 0.75,
        description: "Driver's license number"
      },

      # Passport numbers - various formats
      %{
        type: :passport,
        pattern: ~r/\b(?:Passport|PP)[:\s]*[A-Z0-9]{6,12}\b/i,
        confidence: 0.80,
        description: "Passport number"
      },

      # Bank Account Numbers
      # US routing number (9 digits)
      %{
        type: :financial,
        pattern: ~r/\b(?:Routing|RTN|ABA)[:\s]*\d{9}\b/i,
        confidence: 0.80,
        description: "Bank routing number"
      },

      # Account number (variable length)
      %{
        type: :financial,
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
      },

      # ========================================
      # API Keys and Secrets
      # ========================================

      # OpenAI API Key (sk-...)
      %{
        type: :api_key,
        pattern: ~r/\bsk-[a-zA-Z0-9]{20,}\b/,
        confidence: 0.95,
        description: "OpenAI API key"
      },

      # Anthropic API Key (sk-ant-...)
      %{
        type: :api_key,
        pattern: ~r/\bsk-ant-[a-zA-Z0-9_-]{20,}\b/,
        confidence: 0.95,
        description: "Anthropic API key"
      },

      # AWS Access Key ID (AKIA...)
      %{
        type: :api_key,
        pattern: ~r/\bAKIA[A-Z0-9]{16}\b/,
        confidence: 0.95,
        description: "AWS Access Key ID"
      },

      # AWS Secret Access Key (40 character base64)
      %{
        type: :secret,
        pattern: ~r/\b[A-Za-z0-9\/+=]{40}\b/,
        confidence: 0.60,
        description: "Potential AWS Secret Access Key"
      },

      # AWS Secret Key context pattern
      %{
        type: :secret,
        pattern:
          ~r/(?:aws_secret_access_key|AWS_SECRET_ACCESS_KEY|SecretAccessKey)[:\s=]+['"]?[A-Za-z0-9\/+=]{40}['"]?/i,
        confidence: 0.95,
        description: "AWS Secret Access Key with context"
      },

      # GitHub Personal Access Token (ghp_, gho_, ghu_, ghs_, ghr_)
      %{
        type: :api_key,
        pattern: ~r/\bgh[pousr]_[A-Za-z0-9]{36}\b/,
        confidence: 0.95,
        description: "GitHub Personal Access Token"
      },

      # GitHub OAuth Access Token
      %{
        type: :api_key,
        pattern: ~r/\bgho_[A-Za-z0-9]{36}\b/,
        confidence: 0.95,
        description: "GitHub OAuth Access Token"
      },

      # GitHub App Token
      %{
        type: :api_key,
        pattern: ~r/\bghs_[A-Za-z0-9]{36}\b/,
        confidence: 0.95,
        description: "GitHub App Token"
      },

      # GitHub Refresh Token
      %{
        type: :api_key,
        pattern: ~r/\bghr_[A-Za-z0-9]{36}\b/,
        confidence: 0.95,
        description: "GitHub Refresh Token"
      },

      # Google API Key (AIza...)
      %{
        type: :api_key,
        pattern: ~r/\bAIza[a-zA-Z0-9_-]{35}\b/,
        confidence: 0.95,
        description: "Google API Key"
      },

      # Google OAuth Access Token
      %{
        type: :auth_token,
        pattern: ~r/\bya29\.[a-zA-Z0-9_-]{50,}\b/,
        confidence: 0.95,
        description: "Google OAuth Access Token"
      },

      # Slack API Token (xoxb-, xoxp-, xoxa-, xoxs-)
      %{
        type: :api_key,
        pattern: ~r/\bxox[abps]-[a-zA-Z0-9-]{10,}\b/,
        confidence: 0.95,
        description: "Slack API Token"
      },

      # Stripe API Key (sk_live_, sk_test_, rk_live_, rk_test_)
      %{
        type: :api_key,
        pattern: ~r/\b(?:sk|rk)_(?:live|test)_[a-zA-Z0-9]{24,}\b/,
        confidence: 0.95,
        description: "Stripe API Key"
      },

      # Stripe Publishable Key (pk_live_, pk_test_)
      %{
        type: :api_key,
        pattern: ~r/\bpk_(?:live|test)_[a-zA-Z0-9]{24,}\b/,
        confidence: 0.90,
        description: "Stripe Publishable Key"
      },

      # Twilio Account SID (AC...)
      %{
        type: :api_key,
        pattern: ~r/\bAC[a-f0-9]{32}\b/,
        confidence: 0.95,
        description: "Twilio Account SID"
      },

      # Twilio Auth Token
      %{
        type: :secret,
        pattern: ~r/\b[a-f0-9]{32}\b/,
        confidence: 0.50,
        description: "Potential Twilio Auth Token"
      },

      # Twilio Auth Token with context
      %{
        type: :secret,
        pattern:
          ~r/(?:twilio|TWILIO).*(?:auth_token|AUTH_TOKEN|AuthToken)[:\s=]+['"]?[a-f0-9]{32}['"]?/i,
        confidence: 0.95,
        description: "Twilio Auth Token"
      },

      # SendGrid API Key (SG...)
      %{
        type: :api_key,
        pattern: ~r/\bSG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}\b/,
        confidence: 0.95,
        description: "SendGrid API Key"
      },

      # Mailgun API Key (key-...)
      %{
        type: :api_key,
        pattern: ~r/\bkey-[a-f0-9]{32}\b/,
        confidence: 0.95,
        description: "Mailgun API Key"
      },

      # Mailchimp API Key
      %{
        type: :api_key,
        pattern: ~r/\b[a-f0-9]{32}-us[0-9]{1,2}\b/,
        confidence: 0.90,
        description: "Mailchimp API Key"
      },

      # Slack Webhook URL
      %{
        type: :secret,
        pattern: ~r|https://hooks\.slack\.com/services/T[A-Z0-9]{8}/B[A-Z0-9]{8}/[a-zA-Z0-9]{24}|,
        confidence: 0.95,
        description: "Slack Webhook URL"
      },

      # Discord Bot Token
      %{
        type: :auth_token,
        pattern: ~r/\b[A-Za-z0-9]{24}\.[A-Za-z0-9]{6}\.[A-Za-z0-9_-]{27}\b/,
        confidence: 0.95,
        description: "Discord Bot Token"
      },

      # Generic API Key patterns with context
      %{
        type: :api_key,
        pattern:
          ~r/(?:api[_-]?key|apikey|API[_-]?KEY|API_KEY)[:\s=]+['"]?[a-zA-Z0-9_-]{20,}['"]?/i,
        confidence: 0.85,
        description: "API Key with context"
      },

      # Generic Secret Key patterns with context
      %{
        type: :secret,
        pattern:
          ~r/(?:secret[_-]?key|secretkey|SECRET[_-]?KEY|SECRET_KEY|secret|SECRET|password|PASSWORD|passwd|PASSWD)[:\s=]+['"]?[a-zA-Z0-9_!@#$%^&*()\-+=]{8,}['"]?/i,
        confidence: 0.85,
        description: "Secret key with context"
      },

      # ========================================
      # Authentication Tokens
      # ========================================

      # Bearer Token
      %{
        type: :auth_token,
        pattern: ~r/\bBearer\s+[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\b/,
        confidence: 0.95,
        description: "Bearer JWT Token"
      },

      # JWT Token (three base64 parts separated by dots)
      %{
        type: :auth_token,
        pattern: ~r/\beyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*\b/,
        confidence: 0.95,
        description: "JWT Token"
      },

      # OAuth Access Token pattern
      %{
        type: :auth_token,
        pattern:
          ~r/(?:access_token|ACCESS_TOKEN|AccessToken)[:\s=]+['"]?[a-zA-Z0-9_-]{20,}['"]?/i,
        confidence: 0.90,
        description: "OAuth Access Token"
      },

      # OAuth Refresh Token pattern
      %{
        type: :auth_token,
        pattern:
          ~r/(?:refresh_token|REFRESH_TOKEN|RefreshToken)[:\s=]+['"]?[a-zA-Z0-9_-]{20,}['"]?/i,
        confidence: 0.90,
        description: "OAuth Refresh Token"
      },

      # OAuth Client Secret
      %{
        type: :secret,
        pattern:
          ~r/(?:client_secret|CLIENT_SECRET|ClientSecret)[:\s=]+['"]?[a-zA-Z0-9_-]{20,}['"]?/i,
        confidence: 0.90,
        description: "OAuth Client Secret"
      },

      # ========================================
      # Database Connection Strings
      # ========================================

      # PostgreSQL Connection String
      %{
        type: :secret,
        pattern: ~r|postgres(?:ql)?://[^:]+:[^@]+@[^/]+/[a-zA-Z0-9_]+|,
        confidence: 0.95,
        description: "PostgreSQL Connection String"
      },

      # MySQL Connection String
      %{
        type: :secret,
        pattern: ~r|mysql://[^:]+:[^@]+@[^/]+/[a-zA-Z0-9_]+|,
        confidence: 0.95,
        description: "MySQL Connection String"
      },

      # MongoDB Connection String
      %{
        type: :secret,
        pattern: ~r|mongodb(?:\+srv)?://[^:]+:[^@]+@[^/]+|,
        confidence: 0.95,
        description: "MongoDB Connection String"
      },

      # Redis Connection String
      %{
        type: :secret,
        pattern: ~r|redis://[^:]*:[^@]+@[^/]+|,
        confidence: 0.95,
        description: "Redis Connection String"
      },

      # Generic Database Connection String with password
      %{
        type: :secret,
        pattern:
          ~r/(?:connection[_-]?string|CONNECTION_STRING|ConnectionString)[:\s=]+['\"]?[a-zA-Z0-9+.-]+:\/\/[^:]+:[^@]+@[^\s'\"]+['\"]?/i,
        confidence: 0.90,
        description: "Database Connection String"
      },

      # ========================================
      # Private Keys
      # ========================================

      # RSA Private Key
      %{
        type: :private_key,
        pattern: ~r/-----BEGIN RSA PRIVATE KEY-----[\s\S]*?-----END RSA PRIVATE KEY-----/,
        confidence: 0.99,
        description: "RSA Private Key"
      },

      # EC Private Key
      %{
        type: :private_key,
        pattern: ~r/-----BEGIN EC PRIVATE KEY-----[\s\S]*?-----END EC PRIVATE KEY-----/,
        confidence: 0.99,
        description: "EC Private Key"
      },

      # DSA Private Key
      %{
        type: :private_key,
        pattern: ~r/-----BEGIN DSA PRIVATE KEY-----[\s\S]*?-----END DSA PRIVATE KEY-----/,
        confidence: 0.99,
        description: "DSA Private Key"
      },

      # OpenSSH Private Key
      %{
        type: :private_key,
        pattern: ~r/-----BEGIN OPENSSH PRIVATE KEY-----[\s\S]*?-----END OPENSSH PRIVATE KEY-----/,
        confidence: 0.99,
        description: "OpenSSH Private Key"
      },

      # PGP Private Key Block
      %{
        type: :private_key,
        pattern:
          ~r/-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*?-----END PGP PRIVATE KEY BLOCK-----/,
        confidence: 0.99,
        description: "PGP Private Key"
      },

      # Generic Private Key
      %{
        type: :private_key,
        pattern: ~r/-----BEGIN PRIVATE KEY-----[\s\S]*?-----END PRIVATE KEY-----/,
        confidence: 0.99,
        description: "Private Key"
      },

      # SSH Key fingerprint context
      %{
        type: :private_key,
        pattern:
          ~r/(?:ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+[A-Za-z0-9+\/]+=*\s*.*/,
        confidence: 0.90,
        description: "SSH Public Key"
      },

      # ========================================
      # National IDs (International)
      # ========================================

      # UK National Insurance Number (AB123456C format)
      %{
        type: :national_id,
        pattern: ~r/\b[A-Z]{2}\d{6}[A-Z]\b/,
        confidence: 0.85,
        description: "UK National Insurance Number"
      },

      # UK NHS Number (10 digits)
      %{
        type: :national_id,
        pattern: ~r/\b\d{3}[\s-]?\d{3}[\s-]?\d{4}\b/,
        confidence: 0.60,
        description: "Potential UK NHS Number"
      },

      # Canadian Social Insurance Number (9 digits with optional spaces/dashes)
      %{
        type: :national_id,
        pattern: ~r/\b\d{3}[\s-]?\d{3}[\s-]?\d{3}\b/,
        confidence: 0.60,
        description: "Potential Canadian SIN"
      },

      # Australian Tax File Number (8-9 digits)
      %{
        type: :national_id,
        pattern: ~r/\b\d{8,9}\b/,
        confidence: 0.40,
        description: "Potential Australian TFN"
      },

      # Australian TFN with context
      %{
        type: :national_id,
        pattern: ~r/(?:TFN|Tax File Number|tax file number)[:\s]*\d{8,9}\b/i,
        confidence: 0.90,
        description: "Australian Tax File Number"
      },

      # Australian Medicare Number
      %{
        type: :medical_id,
        pattern: ~r/\b\d{4}[\s-]?\d{5}[\s-]?\d\b/,
        confidence: 0.70,
        description: "Potential Australian Medicare Number"
      },

      # Irish Personal Public Service Number (PPS)
      %{
        type: :national_id,
        pattern: ~r/\b\d{7}[A-Z]\b/,
        confidence: 0.75,
        description: "Irish PPS Number"
      },

      # German Tax ID (Steueridentifikationsnummer)
      %{
        type: :national_id,
        pattern: ~r/\b\d{11}\b/,
        confidence: 0.50,
        description: "Potential German Tax ID"
      },

      # French Social Security Number (INSEE)
      %{
        type: :national_id,
        pattern: ~r/\b\d{13}[0-9A-F]{2}\b/,
        confidence: 0.85,
        description: "French Social Security Number"
      },

      # Spanish DNI/NIE
      %{
        type: :national_id,
        pattern: ~r/\b\d{8}[A-Z]\b/,
        confidence: 0.75,
        description: "Spanish DNI/NIE"
      },

      # Italian Fiscal Code (Codice Fiscale)
      %{
        type: :national_id,
        pattern: ~r/\b[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]\b/,
        confidence: 0.90,
        description: "Italian Fiscal Code"
      },

      # ========================================
      # Device and Hardware Identifiers
      # ========================================

      # MAC Address (various formats)
      %{
        type: :device_id,
        pattern: ~r/\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b/,
        confidence: 0.90,
        description: "MAC Address"
      },

      # MAC Address (Cisco format with dots)
      %{
        type: :device_id,
        pattern: ~r/\b[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\b/,
        confidence: 0.90,
        description: "MAC Address (Cisco format)"
      },

      # UUID/GUID
      %{
        type: :device_id,
        pattern:
          ~r/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/,
        confidence: 0.85,
        description: "UUID/GUID"
      },

      # IMEI Number (15 digits)
      %{
        type: :device_id,
        pattern: ~r/\b\d{15}\b/,
        confidence: 0.40,
        description: "Potential IMEI"
      },

      # IMEI with context
      %{
        type: :device_id,
        pattern: ~r/(?:IMEI|imei)[:\s]*\d{15}\b/,
        confidence: 0.90,
        description: "IMEI Number"
      },

      # Serial Number patterns
      %{
        type: :device_id,
        pattern: ~r/(?:Serial|S\/N|Serial Number)[:\s]*[A-Z0-9-]{6,20}\b/i,
        confidence: 0.85,
        description: "Serial Number"
      },

      # VIN (Vehicle Identification Number) - 17 characters
      %{
        type: :device_id,
        pattern: ~r/\b[A-HJ-NPR-Z0-9]{17}\b/,
        confidence: 0.75,
        description: "Vehicle Identification Number"
      },

      # License Plate (US states)
      %{
        type: :device_id,
        pattern: ~r/\b[A-Z]{1,3}[-\s]?[A-Z0-9]{1,4}[-\s]?[A-Z0-9]{1,4}\b/,
        confidence: 0.50,
        description: "Potential License Plate"
      },

      # ========================================
      # Environment and Config File Patterns
      # ========================================

      # .env file variable assignment
      %{
        type: :secret,
        pattern: ~r/^[A-Z_]+=\S+$/m,
        confidence: 0.70,
        description: "Environment variable"
      },

      # .env file with password context
      %{
        type: :secret,
        pattern:
          ~r/(?:DB_PASS|DATABASE_PASS|DB_PASSWORD|DATABASE_PASSWORD|MYSQL_PASSWORD|POSTGRES_PASSWORD|REDIS_PASSWORD|MONGO_PASSWORD)[:\s=]+\S+/i,
        confidence: 0.95,
        description: "Database password in environment"
      },

      # AWS credentials in config
      %{
        type: :secret,
        pattern: ~r/(?:aws_access_key_id|AWS_ACCESS_KEY_ID)[:\s=]+[A-Z0-9]+/i,
        confidence: 0.95,
        description: "AWS Access Key in config"
      },

      # Kubernetes secrets
      %{
        type: :secret,
        pattern: ~r/(?:apiVersion:\s*v1[\s\S]*?kind:\s*Secret[\s\S]*?data:)/,
        confidence: 0.95,
        description: "Kubernetes Secret manifest"
      },

      # Docker registry password
      %{
        type: :secret,
        pattern: ~r/(?:DOCKER_PASSWORD|docker_password|registry_password)[:\s=]+\S+/i,
        confidence: 0.95,
        description: "Docker registry password"
      },

      # Generic password in URL
      %{
        type: :secret,
        pattern: ~r|[a-zA-Z][a-zA-Z0-9+.-]*://[^:]+:[^@]+@[^\s]+|,
        confidence: 0.90,
        description: "URL with embedded credentials"
      },

      # ========================================
      # Additional Financial Patterns
      # ========================================

      # IBAN (International Bank Account Number)
      %{
        type: :financial,
        pattern: ~r/\b[A-Z]{2}[0-9]{2}[A-Z0-9]{4}[0-9]{7}(?:[A-Z0-9]?){0,16}\b/,
        confidence: 0.90,
        description: "IBAN"
      },

      # SWIFT/BIC Code
      %{
        type: :financial,
        pattern: ~r/\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b/,
        confidence: 0.75,
        description: "SWIFT/BIC Code"
      },

      # Cryptocurrency Wallet Addresses
      # Bitcoin
      %{
        type: :financial,
        pattern: ~r/\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b/,
        confidence: 0.85,
        description: "Bitcoin Address"
      },

      # Bitcoin Bech32 (bc1...)
      %{
        type: :financial,
        pattern: ~r/\bbc1[a-zA-Z0-9]{39,59}\b/,
        confidence: 0.90,
        description: "Bitcoin Bech32 Address"
      },

      # Ethereum Address
      %{
        type: :financial,
        pattern: ~r/\b0x[a-fA-F0-9]{40}\b/,
        confidence: 0.90,
        description: "Ethereum Address"
      },

      # ========================================
      # URLs and Web Resources
      # ========================================

      # Generic URL
      %{
        type: :url,
        pattern: ~r|https?://[^\s<>"]+|,
        confidence: 0.80,
        description: "URL"
      },

      # URL with API key or token in query string
      %{
        type: :secret,
        pattern: ~r/[?&](?:api[_-]?key|apikey|token|access_token|secret|password|key)=[^&\s]+/i,
        confidence: 0.90,
        description: "URL with credential in query string"
      },

      # ========================================
      # Contextual Secret Patterns (for LLM usage)
      # ========================================

      # Hardcoded password in code
      %{
        type: :secret,
        pattern: ~r/(?:password|passwd|pwd)\s*[=:]\s*['"][^'"]{4,}['"]/i,
        confidence: 0.85,
        description: "Hardcoded password in code"
      },

      # Hardcoded API key in code
      %{
        type: :api_key,
        pattern: ~r/(?:api[_-]?key|apikey)\s*[=:]\s*['"][a-zA-Z0-9_-]{20,}['"]/i,
        confidence: 0.90,
        description: "Hardcoded API key in code"
      },

      # Private key assignment in code
      %{
        type: :private_key,
        pattern: ~r/(?:private[_-]?key|privateKey|PRIVATE_KEY)\s*[=:]\s*['"][^'"]+['"]/i,
        confidence: 0.85,
        description: "Private key assignment in code"
      },

      # Token assignment in code
      %{
        type: :auth_token,
        pattern: ~r/(?:auth[_-]?token|bearer[_-]?token|access_token)\s*[=:]\s*['"][^'"]+['"]/i,
        confidence: 0.90,
        description: "Token assignment in code"
      }
    ]
  end
end
