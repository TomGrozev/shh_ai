defmodule ShhAi.TestSupport.DataGenerator do
  @moduledoc """
  Generates deterministic test data with embedded PII for performance and stress testing.

  Uses `:rand` with deterministic seeding so the same seed always produces identical output.
  The seed is logged to stdout for reproducibility.

  ## Options

    * `:size` — `:small` (~1KB), `:medium` (~10KB), `:large` (~50KB), `:xlarge` (~100KB),
      `:xxlarge` (~500KB), `:huge` (~1MB)
    * `:seed` — integer seed or `:random`. Defaults to `42` or the `PERF_SEED` env var.
    * `:pii_types` — list of atoms from `ShhAi.Config.supported_pii_types/0`. Defaults to all.

  ## Examples

      iex> text = ShhAi.TestSupport.DataGenerator.generate_text(size: :small, seed: 42)
      iex> String.contains?(text, "@")
      true

      iex> req = ShhAi.TestSupport.DataGenerator.generate_request(size: :medium, seed: 123)
      iex> is_map(req) and is_list(req["messages"])
      true
  """

  @size_targets %{
    small: 1_024,
    medium: 10_240,
    large: 51_200,
    xlarge: 102_400,
    xxlarge: 512_000,
    huge: 1_048_576
  }

  @templates [
    "My name is {{name}} and I live in {{location}}.",
    "Contact me at {{email}} or call {{phone}}.",
    "My SSN is {{ssn}} and my passport is {{passport}}.",
    "The server IP is {{ip_address}} and device ID is {{device_id}}.",
    "Credit card: {{financial}}. Bank account: {{financial}}.",
    "API key: {{api_key}}. Secret: {{secret}}. Auth token: {{auth_token}}.",
    "Private key: {{private_key}}. National ID: {{national_id}}.",
    "Visit {{url}} for more info from {{organization}}.",
    "My title is {{title}} and I am {{age}} years old.",
    "Date of birth: {{date}}. Medical ID: {{medical_id}}.",
    "Hello, I am {{name}} from {{organization}}. Reach me at {{email}} or {{phone}}.",
    "User {{name}} logged in from {{ip_address}} using device {{device_id}} on {{date}}.",
    "Payment of ${{financial}} processed for {{name}}. Card ending in {{financial}}.",
    "The project at {{location}} is led by {{name}}, a {{title}} aged {{age}}.",
    "Secure endpoint: {{url}}. Credentials: {{api_key}} / {{secret}}.",
    "Patient {{name}} has medical ID {{medical_id}} and DOB {{date}}.",
    "Transaction by {{name}}: SSN {{ssn}}, passport {{passport}}, national ID {{national_id}}.",
    "Token: {{auth_token}}. Private key: {{private_key}}. Secret: {{secret}}.",
    "Company {{organization}} located at {{location}}. Website: {{url}}.",
    "Employee {{name}}, {{title}}, email {{email}}, phone {{phone}}, age {{age}}."
  ]

  defp generate_pii(:name, state) do
    {first, st1} = random_first_name(state)
    {last, st2} = random_last_name(st1)
    {"#{first} #{last}", st2}
  end

  defp generate_pii(:location, state) do
    {street, st1} = random_street(state)
    {city, st2} = random_city(st1)
    {st, st3} = random_state(st2)
    {zip, st4} = random_zip(st3)
    {"#{street}, #{city}, #{st} #{zip}", st4}
  end

  defp generate_pii(:email, state) do
    {user, st1} = random_user(state)
    {domain, st2} = random_domain(st1)
    {"#{user}@#{domain}", st2}
  end

  defp generate_pii(:phone, state) do
    {phone, st1} = random_phone(state)
    {phone, st1}
  end

  defp generate_pii(:ssn, state) do
    {d1, st1} = random_digits(3, state)
    {d2, st2} = random_digits(2, st1)
    {d3, st3} = random_digits(4, st2)
    {"#{d1}-#{d2}-#{d3}", st3}
  end

  defp generate_pii(:financial, state) do
    {d1, st1} = random_digits(4, state)
    {d2, st2} = random_digits(4, st1)
    {d3, st3} = random_digits(4, st2)
    {d4, st4} = random_digits(4, st3)
    {"#{d1} #{d2} #{d3} #{d4}", st4}
  end

  defp generate_pii(:date, state) do
    {year, st1} = random_year(state)
    {month, st2} = random_month(st1)
    {day, st3} = random_day(st2)
    {"#{year}-#{month}-#{day}", st3}
  end

  defp generate_pii(:medical_id, state) do
    {d1, st1} = random_digits(6, state)
    {d2, st2} = random_digits(2, st1)
    {"MED-#{d1}-#{d2}", st2}
  end

  defp generate_pii(:ip_address, state) do
    {o1, st1} = random_octet(state)
    {o2, st2} = random_octet(st1)
    {o3, st3} = random_octet(st2)
    {o4, st4} = random_octet(st3)
    {"#{o1}.#{o2}.#{o3}.#{o4}", st4}
  end

  defp generate_pii(:url, state) do
    {domain, st1} = random_domain(state)
    {path, st2} = random_path(st1)
    {"https://#{domain}/#{path}", st2}
  end

  defp generate_pii(:api_key, state) do
    {val, st} = random_alphanum(32, state)
    {"sk-#{val}", st}
  end

  defp generate_pii(:secret, state) do
    {val, st} = random_alphanum(24, state)
    {"sec-#{val}", st}
  end

  defp generate_pii(:auth_token, state) do
    {val, st} = random_alphanum(40, state)
    {"Bearer #{val}", st}
  end

  defp generate_pii(:private_key, state) do
    {val, st} = random_alphanum(64, state)
    {"-----BEGIN RSA PRIVATE KEY-----\n#{val}\n-----END RSA PRIVATE KEY-----", st}
  end

  defp generate_pii(:national_id, state) do
    {val, st} = random_digits(8, state)
    {"NID-#{val}", st}
  end

  defp generate_pii(:device_id, state) do
    {val, st} = random_alphanum(16, state)
    {"dev-#{val}", st}
  end

  defp generate_pii(:passport, state) do
    {val, st} = random_digits(7, state)
    {"P#{val}", st}
  end

  defp generate_pii(:organization, state), do: random_company(state)
  defp generate_pii(:age, state), do: random_age(state) |> then(fn {a, s} -> {"#{a}", s} end)
  defp generate_pii(:title, state), do: random_title(state) |> then(fn {t, s} -> {"#{t}", s} end)

  @doc """
  Generates text with embedded PII.

  ## Options

    * `:size` — atom size key (default `:small`)
    * `:seed` — integer or `:random` (default from env or 42)
    * `:pii_types` — list of atoms (default all supported types)
  """
  @spec generate_text(keyword()) :: String.t()
  def generate_text(opts \\ []) do
    {state, seed} = init_seed(opts)
    log_seed(seed)

    size = Keyword.get(opts, :size, :small)
    target = Map.fetch!(@size_targets, size)
    pii_types = Keyword.get(opts, :pii_types, all_pii_types())

    {text, _state} = generate_until_target(target, pii_types, state, "")
    text
  end

  @doc """
  Generates an OpenAI-format request body map with embedded PII in messages.

  ## Options

    Same as `generate_text/1`.
  """
  @spec generate_request(keyword()) :: map()
  def generate_request(opts \\ []) do
    text = generate_text(opts)

    %{
      "model" => "gpt-4",
      "messages" => [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => text}
      ]
    }
  end

  # ── Seed handling ────────────────────────────────────────────────────

  defp init_seed(opts) do
    seed =
      case Keyword.get(opts, :seed) do
        nil -> env_seed()
        :random -> :rand.uniform(1_000_000_000)
        n when is_integer(n) -> n
      end

    {:rand.seed_s(:exsss, {seed, seed, seed}), seed}
  end

  defp env_seed do
    case System.get_env("PERF_SEED") do
      nil -> 42
      "random" -> :rand.uniform(1_000_000_000)
      val -> String.to_integer(val)
    end
  end

  defp log_seed(seed) do
    IO.puts("[DataGenerator] seed=#{seed}")
  end

  # ── Text generation ──────────────────────────────────────────────────

  defp generate_until_target(target, pii_types, state, acc) do
    if byte_size(acc) >= target do
      {acc, state}
    else
      {chunk, new_state} = generate_chunk(pii_types, state)
      generate_until_target(target, pii_types, new_state, acc <> chunk)
    end
  end

  defp generate_chunk(pii_types, state) do
    {template, new_state} = pick_random(@templates, state)
    {filled, final_state} = fill_template(template, pii_types, new_state)
    {filled <> "\n\n", final_state}
  end

  defp fill_template(template, pii_types, state) do
    Regex.scan(~r/\{\{(\w+)\}\}/, template)
    |> Enum.reduce({template, state}, fn [match, type_str], {text, st} ->
      type = String.to_existing_atom(type_str)

      if type in pii_types do
        {value, new_st} = generate_value(type, st)
        {String.replace(text, match, value, global: false), new_st}
      else
        {String.replace(text, match, "[REDACTED]", global: false), st}
      end
    end)
  end

  defp pick_random(list, state) do
    {idx, new_state} = :rand.uniform_s(length(list), state)
    {Enum.at(list, idx - 1), new_state}
  end

  defp generate_value(type, state) do
    generate_pii(type, state)
  end

  # ── Random helpers (deterministic via :rand) ────────────────────────

  defp random_first_name(state),
    do:
      pick_random(
        ~w(John Jane Alice Bob Carol Dave Emma Frank Grace Henry Iris Jack Kate Leo Mia Noah Olivia Paul Quinn Ruby Sam Tara Uma Victor Wendy Xavier Yara Zane),
        state
      )

  defp random_last_name(state),
    do:
      pick_random(
        ~w(Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson Martin Lee Perez Thompson White),
        state
      )

  defp random_street(state) do
    {num, st1} = :rand.uniform_s(9999, state)
    {street_type, st2} = pick_random(~w(St Ave Blvd Rd Dr Ln Way Ct Pl), st1)

    {street_name, st3} =
      pick_random(~w(Main Oak Pine Maple Cedar Elm Birch Walnut Cherry Willow), st2)

    {"#{num} #{street_name} #{street_type}", st3}
  end

  defp random_city(state),
    do:
      pick_random(
        ~w(Springfield Riverside Franklin Greenville Madison Clayton Fairview Georgetown Salem),
        state
      )

  defp random_state(state),
    do:
      pick_random(
        ~w(AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY),
        state
      )

  defp random_zip(state) do
    {val, st} = random_digits(5, state)
    {val, st}
  end

  defp random_user(state) do
    {name, st1} = pick_random(~w(john jane alice bob carol dave emma frank grace), state)
    {digits, st2} = random_digits(3, st1)
    {"#{name}#{digits}", st2}
  end

  defp random_domain(state),
    do: pick_random(~w(example.com acme.org company.net test.io demo.biz mail.dev), state)

  defp random_phone(state) do
    {d1, st1} = random_digits(3, state)
    {d2, st2} = random_digits(3, st1)
    {d3, st3} = random_digits(4, st2)
    {"#{d1}-#{d2}-#{d3}", st3}
  end

  defp random_year(state),
    do: :rand.uniform_s(2024 - 1950 + 1, state) |> then(fn {y, s} -> {y + 1950 - 1, s} end)

  defp random_month(state),
    do:
      :rand.uniform_s(12, state)
      |> then(fn {m, s} -> {:io_lib.format("~2..0B", [m]) |> IO.iodata_to_binary(), s} end)

  defp random_day(state),
    do:
      :rand.uniform_s(28, state)
      |> then(fn {d, s} -> {:io_lib.format("~2..0B", [d]) |> IO.iodata_to_binary(), s} end)

  defp random_octet(state), do: :rand.uniform_s(254, state) |> then(fn {o, s} -> {o, s} end)

  defp random_path(state) do
    {segment, st1} = pick_random(~w(api v1 data user admin public private), state)
    {alphanum, st2} = random_alphanum(8, st1)
    {"#{segment}/#{alphanum}", st2}
  end

  defp random_company(state),
    do:
      pick_random(
        ~w(Acme Corp TechCorp Global Industries NextGen Solutions Alpha Dynamics Beta Systems Gamma Corp Delta Innovations),
        state
      )

  defp random_age(state),
    do: :rand.uniform_s(80 - 18 + 1, state) |> then(fn {a, s} -> {a + 18 - 1, s} end)

  defp random_title(state),
    do:
      pick_random(
        ~w(Engineer Manager Director Analyst Designer Developer Architect Consultant Administrator Coordinator Specialist),
        state
      )

  defp random_digits(n, state) do
    Enum.reduce(1..n, {"", state}, fn _, {acc, st} ->
      {d, new_st} = :rand.uniform_s(10, st)
      {"#{acc}#{d - 1}", new_st}
    end)
  end

  defp random_alphanum(n, state) do
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    len = String.length(chars)

    Enum.reduce(1..n, {"", state}, fn _, {acc, st} ->
      {idx, new_st} = :rand.uniform_s(len, st)
      {"#{acc}#{String.at(chars, idx - 1)}", new_st}
    end)
  end

  defp all_pii_types do
    [
      :name,
      :location,
      :email,
      :phone,
      :ssn,
      :financial,
      :date,
      :medical_id,
      :ip_address,
      :url,
      :api_key,
      :secret,
      :auth_token,
      :private_key,
      :national_id,
      :device_id,
      :passport,
      :organization,
      :age,
      :title
    ]
  end
end
