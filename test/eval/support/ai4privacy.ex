defmodule ShhAi.Eval.AI4Privacy do
  @moduledoc """
  Loads the AI4Privacy `pii-masking-200k` dataset for the detection benchmark.

  The dataset is not vendored: it is downloaded from its public HuggingFace
  mirror on first use and cached on the machine (see `cache_dir/0`). `docs/1`
  returns a seeded, reservoir-sampled subset so a run is fast and reproducible
  across invocations.

  Each row is a JSON object whose `source_text` carries the PII and whose
  `privacy_mask` lists the gold annotations as `%{"label", "start", "end"}`
  maps. `label_mapping/0` is the hand-authored bridge from those dataset
  labels to the ShhAi detector's PII types; `map_annotations/1` applies it and
  drops labels ShhAi has no detector for, so the score is taken over the types
  ShhAi actually claims to detect. The benchmark enables every supported type
  (`ShhAi.Config.supported_pii_types/0`), so the mapping covers the detector's
  full type space.
  """

  @dataset_url "https://huggingface.co/datasets/ai4privacy/pii-masking-200k/resolve/main/english_pii_43k.jsonl"
  @default_cache_subdir ["shh_ai", "eval"]
  @default_limit 5_000
  @default_seed 42

  # AI4Privacy label -> ShhAi detector type (`ShhAi.PII.Patterns.pii_type/0`).
  #
  # Only labels with a genuine detector counterpart are mapped; every other
  # dataset label is intentionally absent and its annotations are dropped from
  # scoring (see `map_annotations/1`). Keeping this mapping explicit and in one
  # place is what makes the benchmark honest: the gold set is projected onto
  # the detector's own type space rather than the detector being asked to
  # reproduce AI4Privacy's 54-class taxonomy.
  #
  # The benchmark runs the detector with every supported type enabled
  # (`ShhAi.Config.supported_pii_types/0`), so the `:date`, `:age`,
  # `:organization` and `:title` types are live here.
  @label_mapping %{
    # Person names
    "FIRSTNAME" => :name,
    "LASTNAME" => :name,
    "MIDDLENAME" => :name,
    # Contact
    "EMAIL" => :email,
    "PHONENUMBER" => :phone,
    # Government / financial identifiers
    "SSN" => :ssn,
    "IDCARDNUM" => :national_id,
    "IBAN" => :financial,
    "BIC" => :financial,
    "ACCOUNTNUMBER" => :financial,
    "BITCOINADDRESS" => :financial,
    "ETHEREUMADDRESS" => :financial,
    "LITECOINADDRESS" => :financial,
    "CREDITCARDNUMBER" => :financial,
    # Credentials
    "APIKEY" => :api_key,
    "PASSWORD" => :secret,
    "PIN" => :secret,
    "CREDITCARDCVV" => :secret,
    # Network
    "IP" => :ip_address,
    "IPV4" => :ip_address,
    "IPV6" => :ip_address,
    "URL" => :url,
    # Device identifiers
    "MAC" => :device_id,
    "PHONEIMEI" => :device_id,
    "VEHICLEVIN" => :device_id,
    "VEHICLEVRM" => :device_id,
    "VEHICLEPLATE" => :device_id,
    # Dates
    "DATE" => :date,
    "DOB" => :date,
    "TIME" => :date,
    # Age
    "AGE" => :age,
    # Organisation
    "COMPANYNAME" => :organization,
    # Job title (the NER model's TITLE label — a role, distinct from HONORIFIC).
    # Kept in the mapping: :title is a supported type, and dropping JOBTITLE
    # would hide a recall gap instead of fixing it.
    "JOBTITLE" => :title,
    # Addresses
    "CITY" => :location,
    "STATE" => :location,
    "COUNTY" => :location,
    "STREET" => :location,
    "SECONDARYADDRESS" => :location,
    "BUILDINGNUMBER" => :location,
    "ZIPCODE" => :location,
    "NEARBYGPSCOORDINATE" => :location,
    "ORDINALDIRECTION" => :location
  }

  # Dropped labels (no detector counterpart, or not personal data):
  #   PREFIX, CREDITCARDISSUER, ACCOUNTNAME — label-like values, not personal
  #     data: honorifics ("Mr.") and card/account issuer names. The detector
  #     has no recogniser for them, so scoring them would only add noise.
  #   AMOUNT, CURRENCY*,
  #     MASKEDNUMBER, USERNAME, USERAGENT — no ShhAi type.
  #   EYECOLOR, GENDER, HEIGHT, SEX, JOBAREA, JOBTYPE — no ShhAi type.

  @doc """
  The URL the dataset is downloaded from.
  """
  @spec dataset_url() :: String.t()
  def dataset_url, do: @dataset_url

  @doc """
  The directory the dataset is cached in.

  Defaults to `~/.cache/shh_ai/eval`, overridable with `SHHAI_EVAL_CACHE_DIR`.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    System.get_env("SHHAI_EVAL_CACHE_DIR") ||
      Path.join([System.user_home!(), ".cache" | @default_cache_subdir])
  end

  @doc """
  Returns a seeded subset of dataset documents.

  ## Options

    * `:limit` - number of documents to sample (default #{@default_limit})
    * `:seed` - seed for the deterministic reservoir sample (default #{@default_seed})
    * `:url` - dataset URL (default `dataset_url/0`)
    * `:cache_dir` - cache directory (default `cache_dir/0`)

  Each returned document is `%{id: term, text: String.t, annotations: [map]}`,
  where `annotations` are the raw dataset labels (use `map_annotations/1` to
  project them onto ShhAi's types).
  """
  @spec docs(keyword()) :: [map()]
  def docs(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    seed = Keyword.get(opts, :seed, @default_seed)
    url = Keyword.get(opts, :url, dataset_url())
    dir = Keyword.get(opts, :cache_dir, cache_dir())

    url
    |> ensure_downloaded!(dir)
    |> File.stream!([])
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> reservoir(limit, seed)
    |> Enum.map(&parse_line/1)
  end

  @doc """
  Parses one JSONL line into a document map.

  `privacy_mask` is normally a decoded list; older dataset revisions serialise
  it as a JSON string, so both shapes are accepted.
  """
  @spec parse_line(String.t()) :: map()
  def parse_line(line) do
    row = Jason.decode!(line)

    %{
      id: row["id"],
      text: row["source_text"],
      annotations: row |> raw_annotations() |> Enum.map(&normalise_annotation/1)
    }
  end

  @doc """
  The AI4Privacy label -> ShhAi PII type mapping authored for this suite.
  """
  @spec label_mapping() :: %{String.t() => atom()}
  def label_mapping, do: @label_mapping

  @doc """
  The set of ShhAi PII types this benchmark scores.
  """
  @spec mapped_types() :: MapSet.t()
  def mapped_types, do: @label_mapping |> Map.values() |> MapSet.new()

  @doc """
  Projects raw dataset annotations onto ShhAi's types.

  Annotations whose label has no mapping are dropped.
  """
  @spec map_annotations([map()]) :: [map()]
  def map_annotations(annotations) do
    Enum.flat_map(annotations, fn %{label: label, start: start_pos, end: end_pos} ->
      case Map.fetch(@label_mapping, label) do
        {:ok, type} -> [%{type: type, start: start_pos, end: end_pos}]
        :error -> []
      end
    end)
  end

  defp ensure_downloaded!(url, dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, Path.basename(URI.parse(url).path))

    if File.regular?(path) and File.stat!(path).size > 0 do
      path
    else
      download!(url, path)
      path
    end
  end

  defp download!(url, path) do
    part = path <> ".part"
    Req.get!(url, into: File.stream!(part), receive_timeout: 600_000)
    File.rename!(part, path)
  end

  # Deterministic single-pass reservoir sampling: every line has an equal
  # chance of landing in the subset, the same seed always yields the same
  # subset, and memory stays bounded by `limit`.
  defp reservoir(stream, limit, seed) do
    :rand.seed(:exsss, {seed, seed, seed})

    stream
    |> Stream.with_index(1)
    |> Enum.reduce({0, []}, fn {line, count}, {_seen, acc} ->
      {count, put_reservoir(count, acc, line, limit)}
    end)
    |> elem(1)
  end

  defp put_reservoir(count, acc, line, limit) when count <= limit, do: [line | acc]

  defp put_reservoir(count, acc, line, limit) do
    index = :rand.uniform(count)
    if index <= limit, do: List.replace_at(acc, index - 1, line), else: acc
  end

  defp raw_annotations(row) do
    case row["privacy_mask"] do
      list when is_list(list) -> list
      binary when is_binary(binary) -> Jason.decode!(binary)
      _ -> []
    end
  end

  defp normalise_annotation(annotation) do
    %{
      label: annotation["label"],
      start: annotation["start"],
      end: annotation["end"],
      value: annotation["value"]
    }
  end
end
