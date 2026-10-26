defmodule ShhAi.PII.NER do
  @moduledoc """
  NER-based PII detection using a fine-tuned BERT-small model via Bumblebee.

  This module provides neural network-based PII detection using a token
  classification model from HuggingFace. The model is selected through
  `PII_NER_MODEL` / `PII_NER_MODEL_REVISION` (`ShhAi.Config`, `model_spec/0`);
  the default is the shipped `gravitee-io/bert-small-pii-detection`. It supports
  24 PII entity types:

  - PERSON, AGE, TITLE, NRP
  - EMAIL_ADDRESS, PHONE_NUMBER
  - CREDIT_CARD, FINANCIAL, IBAN_CODE, US_BANK_NUMBER
  - US_SSN, US_DRIVER_LICENSE, US_ITIN, US_PASSPORT, US_LICENSE_PLATE
  - LOCATION, DATE_TIME, COORDINATE
  - IP_ADDRESS, MAC_ADDRESS, IMEI, URL
  - PASSWORD
  - ORGANIZATION

  ## Architecture

  The module uses Nx.Serving for efficient batch processing and caching.
  The model is loaded once at startup and kept in memory for fast inference.

  ## Performance Considerations

  - Model is loaded once and cached in :persistent_term
  - Uses EXLA backend for optimized inference
  - One serving per sequence-length bucket (see `@sequence_lengths`), each
    warmed at boot, so a short input is padded only up to the next bucket
    instead of the model maximum (512)
  - Long texts are split into overlapping token windows and stitched back
    into full-text byte offsets, so nothing is lost to truncation
  - BERT-small model (~110MB) is 4.4x smaller than RoBERTa-base

  ## Confidence Calibration

  Neural network softmax outputs are often poorly calibrated, producing
  overconfident predictions. This module implements temperature scaling
  to improve calibration:

  - Raw model confidence is "sharpened" or "flattened" by a temperature parameter
  - Higher temperature (> 1.0) reduces overconfidence
  - Cross-validation with regex patterns further calibrates confidence

  ## Hybrid Detection Strategy

  This module is designed to work alongside regex-based detection:

  1. Regex detection is fast and catches well-formatted PII
  2. NER detection catches contextual PII that regex might miss
  3. Results are merged and deduplicated
  """

  require Logger

  # The ML stack (Bumblebee/Nx/EXLA) is present in the full build and absent
  # in the slim, regex-only build (mix.exs `ml_deps/0`, ticket #70). Resolve
  # it at compile time so the ML-only code paths are compiled out of the slim
  # build instead of warning about undefined modules.
  @ml_available Code.ensure_loaded?(Bumblebee)

  # The model's positional embeddings cap the input at 512 wordpiece tokens
  # including the [CLS]/[SEP] special tokens.
  @max_sequence_length 512
  @content_tokens @max_sequence_length - 2

  # Long texts are split into windows of at most `@content_tokens` tokens with
  # `@overlap_tokens` of overlap, so an entity straddling a window boundary
  # still lands whole inside one of the two windows.
  @overlap_tokens 64

  # EXLA compiles one graph per (batch, sequence) shape. Padding every input to
  # 512 made a 10-token sentence cost the same as a 500-token one, so short
  # inputs paid several times their real cost. One serving per bucket pads an
  # input only up to the next bucket size. Every bucket is warmed at boot so the
  # first request never pays EXLA compilation.
  @sequence_lengths [32, 64, 128, 256, 512]

  # Mapping from NER model labels to our PII types
  # The model uses BIO tagging (B- for beginning, I- for inside)
  @ner_label_to_pii_type %{
    # Person information
    "PERSON" => :name,
    "AGE" => :age,
    "TITLE" => :title,
    "NRP" => :name,

    # Contact information
    "EMAIL_ADDRESS" => :email,
    "PHONE_NUMBER" => :phone,

    # Financial
    "CREDIT_CARD" => :financial,
    "FINANCIAL" => :financial,
    "IBAN_CODE" => :financial,
    "US_BANK_NUMBER" => :financial,

    # Government IDs
    "US_SSN" => :ssn,
    "US_DRIVER_LICENSE" => :national_id,
    "US_ITIN" => :national_id,
    "US_PASSPORT" => :passport,
    "US_LICENSE_PLATE" => :device_id,

    # Location/Dates
    "LOCATION" => :location,
    "DATE_TIME" => :date,
    "COORDINATE" => :location,

    # Technology identifiers
    "IP_ADDRESS" => :ip_address,
    "MAC_ADDRESS" => :device_id,
    "IMEI" => :device_id,
    "URL" => :url,

    # Credentials
    "PASSWORD" => :secret,

    # Organization
    "ORGANIZATION" => :organization,

    # Fine-tuned model labels (issue #79). A model we train ourselves tags BIO
    # spans with the *uppercase name of a ShhAi supported PII type* (contract
    # item 1), so the same fine-tuned model works without a code change. Kept
    # in one flat map with the gravitee labels above; the two namespaces do not
    # collide. Labels already present above (LOCATION, ORGANIZATION, TITLE,
    # AGE, FINANCIAL, URL, IP_ADDRESS) are not repeated.
    "NAME" => :name,
    "DATE" => :date,
    "PHONE" => :phone,
    "EMAIL" => :email,
    "SSN" => :ssn,
    "PASSPORT" => :passport,
    "NATIONAL_ID" => :national_id,
    "DEVICE_ID" => :device_id,
    "MEDICAL_ID" => :medical_id,
    "SECRET" => :secret
  }

  # The optional per-type confidence thresholds a fine-tuned model ships next
  # to its weights (`training/train.py` writes it, `training/export.py` copies
  # it). Absent for the shipped gravitee model.
  @thresholds_filename "pii_thresholds.json"

  @type detection :: %{
          type: atom(),
          value: String.t(),
          start_pos: non_neg_integer(),
          end_pos: non_neg_integer(),
          confidence: float(),
          description: String.t(),
          source: :ner
        }

  @type model_spec :: {:hf, String.t()} | {:hf, String.t(), keyword()} | {:local, String.t()}

  @doc """
  Returns the label mapping for this model.
  """
  @spec label_mapping() :: %{String.t() => atom()}
  def label_mapping, do: @ner_label_to_pii_type

  @doc """
  Builds the Bumblebee model spec from `ShhAi.Config`.

  A configured model value that starts with `/` or `.` is a local directory and
  becomes `{:local, path}`; anything else is a HuggingFace repo id and becomes
  `{:hf, repo}`, carrying `revision:` when `PII_NER_MODEL_REVISION` is set.
  """
  @spec model_spec() :: model_spec()
  def model_spec do
    model_spec(ShhAi.Config.pii_ner_model(), ShhAi.Config.pii_ner_model_revision())
  end

  @doc false
  @spec model_spec(String.t(), String.t() | nil) :: model_spec()
  def model_spec(model, revision) when is_binary(model) do
    cond do
      local_path?(model) -> {:local, model}
      revision in [nil, ""] -> {:hf, model}
      true -> {:hf, model, revision: revision}
    end
  end

  defp local_path?("/" <> _), do: true
  defp local_path?("." <> _), do: true
  defp local_path?(_), do: false

  @doc """
  Loads the optional per-type confidence thresholds of a model spec.

  Returns `{:ok, %{pii_type => threshold}}`, or `{:ok, %{}}` when the model
  ships no `pii_thresholds.json` (the shipped gravitee model has none). A file
  that exists but is invalid (unknown PII type, or a value that is not a number
  from 0 to 1) returns `{:error, {:invalid_thresholds_file, source, detail}}`
  so boot fails closed (ADR 0014).

  A local model directory is read directly. A HuggingFace repo is fetched
  through `Bumblebee.HuggingFace.Hub`, so it uses the same revision, cache and
  `BUMBLEBEE_OFFLINE` behaviour as the model files.
  """
  @spec load_type_thresholds(model_spec()) :: {:ok, %{atom() => float()}} | {:error, term()}
  def load_type_thresholds({:local, dir}) do
    dir
    |> Path.join(@thresholds_filename)
    |> read_thresholds_file()
  end

  def load_type_thresholds({:hf, repo}), do: fetch_hub_thresholds(repo, nil)

  def load_type_thresholds({:hf, repo, opts}) do
    fetch_hub_thresholds(repo, Keyword.get(opts, :revision))
  end

  # Per-type precedence: the operator's `PII_NER_TYPE_THRESHOLDS` entry wins
  # over the model's own threshold for the same type. Types in neither map fall
  # back to the global `PII_NER_CONFIDENCE_THRESHOLD` in `above_threshold?/3`.
  @doc false
  @spec effective_type_thresholds(%{atom() => float()}, %{atom() => float()}) ::
          %{atom() => float()}
  def effective_type_thresholds(model_thresholds, env_thresholds) do
    Map.merge(model_thresholds, env_thresholds)
  end

  @doc """
  Returns the per-type NER confidence thresholds in effect.

  The model's `pii_thresholds.json` is the base map; a `PII_NER_TYPE_THRESHOLDS`
  entry overrides it for the same type. Types in neither map use
  `pii_ner_confidence_threshold/0`.
  """
  @spec type_thresholds() :: %{atom() => float()}
  def type_thresholds do
    :persistent_term.get({__MODULE__, :type_thresholds}, config_ner_type_thresholds())
  end

  @doc """
  Initializes the NER model and tokenizer.

  This should be called at application startup. The model and tokenizer
  are cached in :persistent_term for fast access during inference.

  ## Options

    * `:backend` - Nx backend to use (default: :exla)
    * `:device` - Device to run on (default: :host)

  ## Examples

      ShhAi.PII.NER.init()
      #=> :ok

  """
  @spec init(opts :: keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    if initialized?() do
      :ok
    else
      init_ml(opts)
    end
  end

  # ML-only code paths: compiled in the full build, compiled out of the
  # slim build where the deps are absent. `load_model/1` is the real init.
  if @ml_available do
    defp init_ml(opts), do: load_model(opts)

    defp load_model(opts) do
      backend = Keyword.get(opts, :backend, EXLA.Backend)
      device = Keyword.get(opts, :device, :host)

      spec = model_spec()

      Logger.info("Loading NER model from #{inspect(spec)}...")

      # Set Nx global default backend
      Nx.global_default_backend(backend)

      # Load and validate the thresholds file before the weights, so an invalid
      # file fails boot without paying for a model download and EXLA compile.
      with {:ok, model_thresholds} <- load_type_thresholds(spec),
           {:ok, model} <- Bumblebee.load_model(spec),
           {:ok, tokenizer} <- Bumblebee.load_tokenizer(spec) do
        # Token offsets are UTF-8 byte indices into the input, which is what we
        # need to slice values out of the original binary (see `to_detection/2`).
        tokenizer =
          Bumblebee.configure(tokenizer,
            return_special_tokens_mask: true,
            return_offsets: true
          )

        servings = build_servings(model, tokenizer, device)
        warm_servings(servings)

        thresholds = effective_type_thresholds(model_thresholds, config_ner_type_thresholds())

        # Store in persistent_term for fast access
        :persistent_term.put({__MODULE__, :servings}, servings)
        :persistent_term.put({__MODULE__, :tokenizer}, tokenizer)
        :persistent_term.put({__MODULE__, :type_thresholds}, thresholds)
        :persistent_term.put({__MODULE__, :initialized}, true)

        log_type_thresholds(spec, thresholds)
        Logger.info("NER model loaded successfully")
        :ok
      else
        {:error, reason} = error ->
          Logger.error("Failed to load NER model: #{inspect(reason)}")
          error
      end
    end

    defp build_servings(model, tokenizer, device) do
      Map.new(@sequence_lengths, fn length ->
        serving =
          Bumblebee.Text.token_classification(
            model,
            tokenizer,
            # No aggregation: we group tokens ourselves (`group_tokens/1`),
            # reproducing `:same`'s label-based grouping while also stitching
            # wordpiece continuation pieces (`##smith`) into their word.
            aggregation: nil,
            # Keep the "O" tokens. Bumblebee filters them by default, but they
            # are what *breaks* an entity: `:same` groups over the full label
            # sequence, so an `O` token between two `I-X` runs ends the first
            # entity. Filtering them out here would make those runs look
            # adjacent and fuse two real entities into one. We drop `:unknown`
            # (the "O" label) ourselves after grouping instead.
            ignored_labels: [],
            compile: [batch_size: 1, sequence_length: length],
            defn_options: [compiler: EXLA, client: device]
          )

        {length, serving}
      end)
    end

    # Run every bucket once so EXLA compiles its graph at boot rather than on
    # the first request that happens to need that length.
    defp warm_servings(servings) do
      Enum.each(servings, fn {_length, serving} ->
        Nx.Serving.run(serving, "warm up")
      end)
    end

    defp detect_windows(text) do
      tokenizer = :persistent_term.get({__MODULE__, :tokenizer})
      tokens = content_tokens(tokenizer, text)

      text
      |> windows(tokens)
      |> Enum.flat_map(fn {window_text, offset, token_count} ->
        window_text
        |> run_window(token_count)
        |> group_tokens()
        |> Enum.reject(&(&1.type == :unknown))
        |> Enum.map(fn entity ->
          %{entity | start: entity.start + offset, end: entity.end + offset}
        end)
      end)
      |> deduplicate()
    end

    # Runs one window through the smallest bucket that fits its tokens.
    defp run_window(window_text, token_count) do
      servings = :persistent_term.get({__MODULE__, :servings})
      serving = Map.fetch!(servings, pick_bucket(token_count + 2))

      serving
      |> Nx.Serving.run(window_text)
      |> extract_entities()
    end

    defp pick_bucket(token_count) do
      Enum.find(@sequence_lengths, List.last(@sequence_lengths), &(token_count <= &1))
    end

    # The byte offsets of every non-special token, so windows can be cut on
    # token boundaries while staying anchored to the original binary.
    defp content_tokens(tokenizer, text) do
      inputs = Bumblebee.apply_tokenizer(tokenizer, text)

      Enum.zip([
        Nx.to_flat_list(inputs["start_offsets"]),
        Nx.to_flat_list(inputs["end_offsets"]),
        Nx.to_flat_list(inputs["special_tokens_mask"])
      ])
      |> Enum.filter(fn {_start, _end, special?} -> special? == 0 end)
      |> Enum.map(fn {start, finish, _special?} -> {start, finish} end)
    end

    # Splits `tokens` into overlapping windows of at most `@content_tokens`
    # tokens. Returns `{window_text, byte_offset, token_count}` per window; a
    # text short enough for one window is returned whole.
    defp windows(text, tokens) do
      count = length(tokens)

      if count <= @content_tokens do
        [{text, 0, count}]
      else
        step = @content_tokens - @overlap_tokens
        tokens = List.to_tuple(tokens)

        count
        |> window_starts(step)
        |> Enum.map(fn i ->
          last = min(i + @content_tokens, count) - 1
          {first_start, _} = elem(tokens, i)
          {_, last_end} = elem(tokens, last)

          {binary_part(text, first_start, last_end - first_start), first_start, last - i + 1}
        end)
      end
    end

    defp window_starts(count, step) do
      Stream.iterate(0, &(&1 + step))
      |> Stream.take_while(&(&1 < count))
      |> Enum.to_list()
    end

    # Same hub URL shape Bumblebee uses for weights, so the revision, cache
    # directory and `BUMBLEBEE_OFFLINE` behaviour match the model files.
    defp fetch_hub_thresholds(repo, revision) do
      alias Bumblebee.HuggingFace.Hub

      url = Hub.file_url(repo, @thresholds_filename, revision)

      case Hub.cached_download(url) do
        {:ok, path} ->
          read_thresholds_file(path)

        {:error, message} ->
          # A model without thresholds is the common case (the shipped
          # gravitee model has none): the hub reports that as "file not found"
          # online and as a cache miss offline. Both mean "no thresholds", not
          # a boot failure.
          if missing_hub_file?(message),
            do: {:ok, %{}},
            else: {:error, {:thresholds_download_failed, message}}
      end
    end

    defp missing_hub_file?(message) do
      String.contains?(message, "file not found") or
        String.contains?(message, "could not find file in local cache")
    end
  else
    defp init_ml(_opts), do: {:error, :ner_unavailable}
    defp load_model(_opts), do: {:error, :ner_unavailable}
    defp detect_windows(_text), do: raise("NER is unavailable in this regex-only build")
    defp fetch_hub_thresholds(_repo, _revision), do: {:error, :ner_unavailable}
  end

  @doc """
  Returns whether the NER model is initialized and ready.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    :persistent_term.get({__MODULE__, :initialized}, false)
  end

  @doc """
  Detects PII entities in text using NER model.

  Returns a list of detections with type, value, position, and confidence.
  Positions are byte offsets into the full input text regardless of its length.

  ## Options

    * `:confidence_threshold` - Minimum confidence for types without a
      per-type threshold (default: from config)
    * `:type_thresholds` - Map of PII type to confidence threshold, overriding
      `:confidence_threshold` for those types (default: the model's
      `pii_thresholds.json`, overridden by `PII_NER_TYPE_THRESHOLDS`)
    * `:calibrate` - Whether to apply confidence calibration (default: true)

  ## Examples

      ShhAi.PII.NER.detect("My email is john@example.com")
      #=> [%{type: :email, value: "john@example.com", ...}]

  """
  @spec detect(text :: String.t(), opts :: keyword()) :: {:ok, [detection()]} | {:error, term()}
  def detect(text, opts \\ []) when is_binary(text) do
    unless initialized?() do
      raise "NER model not initialized. Call ShhAi.PII.NER.init/1 first."
    end

    confidence_threshold = Keyword.get_lazy(opts, :confidence_threshold, &config_ner_threshold/0)
    type_thresholds = Keyword.get_lazy(opts, :type_thresholds, fn -> type_thresholds() end)
    calibrate? = Keyword.get(opts, :calibrate, true)
    temperature = Keyword.get_lazy(opts, :temperature, &config_ner_temperature/0)

    try do
      detections =
        text
        |> detect_windows()
        |> Stream.map(&to_detection(&1, text))
        |> maybe_calibrate_confidence(calibrate?, temperature)
        |> Enum.filter(&above_threshold?(&1, confidence_threshold, type_thresholds))

      {:ok, detections}
    rescue
      e ->
        Logger.error("NER detection failed: #{inspect(e)}")
        {:error, :ner_detection_failed}
    end
  end

  # Private functions

  defp extract_entities(result) do
    # The token classification result contains entity predictions
    # Format: %{entities: [%{label: "B-PERSON", score: 0.95, start: 0, end: 5, ...}, ...]}
    case result do
      %{entities: entities} when is_list(entities) ->
        entities

      entities when is_list(entities) ->
        # Handle case where result is directly the entities list
        entities

      _ ->
        Logger.warning("Unexpected NER result format: #{inspect(result)}")
        []
    end
  end

  # Groups consecutive tokens that belong to the same entity, averaging their
  # scores, exactly as Bumblebee's `:same` aggregation does -- but with the
  # token stream intact, since we keep the "O" tokens (see `build_servings/3`).
  # A token continues the running entity when its label is `I-<base>` for the
  # *same* base label the entity started with (so `I-IMEI` and
  # `I-US_LICENSE_PLATE` -- both `:device_id` -- stay separate), or when it is a
  # wordpiece continuation piece (`##smith`). A `B-X` token that starts a new
  # word is a new entity: the model emits one `B-X` per real entity (e.g. a
  # first and a last name), so fusing those would merge two gold spans into one
  # and the one-to-one scorer would lose one to a false negative.
  defp group_tokens(tokens) do
    tokens
    |> Enum.reduce([], &add_token/2)
    |> Enum.reverse()
    |> Enum.map(&finalize_group/1)
  end

  defp add_token(token, [group | rest] = groups) do
    if mergeable?(group, token),
      do: [merge(group, token) | rest],
      else: [new_group(token) | groups]
  end

  defp add_token(token, []), do: [new_group(token)]

  defp new_group(token) do
    %{
      label: base_label(token.label),
      type: pii_type_for_label(token.label),
      start: token.start,
      end: token.end,
      score_sum: token.score,
      count: 1
    }
  end

  defp mergeable?(group, token) do
    group.label == base_label(token.label) and
      token.start >= group.end and
      (inside_label?(token.label) or subword_piece?(token))
  end

  defp inside_label?("I-" <> _), do: true
  defp inside_label?(_), do: false

  # BERT wordpiece continuations carry the `##` prefix; the token's decoded
  # form is available on the entity as `:phrase`.
  defp subword_piece?(%{phrase: "##" <> _}), do: true
  defp subword_piece?(_), do: false

  defp merge(group, token) do
    %{group | end: token.end, score_sum: group.score_sum + token.score, count: group.count + 1}
  end

  defp finalize_group(group) do
    %{
      type: group.type,
      start: group.start,
      end: group.end,
      score: group.score_sum / group.count
    }
  end

  defp pii_type_for_label(label) do
    Map.get(@ner_label_to_pii_type, base_label(label), :unknown)
  end

  defp base_label(label) do
    label
    |> String.replace_prefix("B-", "")
    |> String.replace_prefix("I-", "")
  end

  # Overlapping windows produce the same entity twice; a window boundary can
  # also leave a truncated copy of an entity in the neighbouring window. Drop an
  # entity that overlaps an already-kept entity of the same type, keeping the
  # longest span (and, at equal span, the higher score).
  defp deduplicate(entities) do
    entities
    |> Enum.sort_by(&{&1.start, -(&1.end - &1.start), -&1.score})
    |> Enum.reduce([], fn entity, kept ->
      if Enum.any?(kept, &(&1.type == entity.type and overlaps?(&1, entity))) do
        kept
      else
        [entity | kept]
      end
    end)
    |> Enum.reverse()
  end

  defp overlaps?(a, b), do: a.start < b.end and b.start < a.end

  defp to_detection(entity, text) do
    %{
      type: entity.type,
      # NER offsets are UTF-8 byte indices, so slice the binary directly;
      # `String.slice/2` would count graphemes and corrupt non-ASCII values.
      value: binary_part(text, entity.start, entity.end - entity.start),
      start_pos: entity.start,
      end_pos: entity.end,
      confidence: entity.score,
      description: description_for_type(entity.type),
      source: :ner
    }
  end

  defp above_threshold?(%{confidence: confidence} = detection, global, type_thresholds) do
    confidence >= Map.get(type_thresholds, detection.type, global)
  end

  defp description_for_type(:name), do: "Person name (NER)"
  defp description_for_type(:email), do: "Email address (NER)"
  defp description_for_type(:phone), do: "Phone number (NER)"
  defp description_for_type(:ssn), do: "Social Security Number (NER)"
  defp description_for_type(:financial), do: "Financial/Credit card number (NER)"
  defp description_for_type(:date), do: "Date (NER)"
  defp description_for_type(:location), do: "Address/Location (NER)"
  defp description_for_type(:ip_address), do: "IP address (NER)"
  defp description_for_type(:organization), do: "Organization (NER)"
  defp description_for_type(:age), do: "Age (NER)"
  defp description_for_type(:title), do: "Title (NER)"
  defp description_for_type(:national_id), do: "National/Government ID (NER)"
  defp description_for_type(:url), do: "URL (NER)"
  defp description_for_type(:secret), do: "Password/Secret (NER)"
  defp description_for_type(:device_id), do: "Device identifier (NER)"
  defp description_for_type(:passport), do: "Passport number (NER)"
  defp description_for_type(_), do: "Unknown PII type (NER)"

  defp maybe_calibrate_confidence(detections, false, _temperature), do: detections

  defp maybe_calibrate_confidence(detections, true, temperature)
       when is_float(temperature) and temperature > 0 do
    Stream.map(detections, fn detection ->
      calibrated = apply_temperature_scaling(detection.confidence, temperature)
      %{detection | confidence: calibrated}
    end)
  end

  # Higher temperature (> 1.0) reduces confidence (flattens distribution)
  # Lower temperature (< 1.0) increases confidence (sharpens distribution)
  # calibrated_confidence = 1 / (1 + exp(-(log(p/(1-p)) / temperature)))
  defp apply_temperature_scaling(confidence, temperature)
       when is_float(confidence) and is_float(temperature) and temperature > 0 do
    # Clamp confidence to avoid log(0) or division issues
    clamped = confidence |> max(0.001) |> min(0.999)

    # Convert probability to logit (log-odds)
    logit = :math.log(clamped / (1 - clamped))

    # Apply temperature scaling
    scaled_logit = logit / temperature

    # Convert back to probability via sigmoid
    1 / (1 + :math.exp(-scaled_logit))
  end

  defp read_thresholds_file(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_type_thresholds(content, path)

      # A missing file is not an error: most models ship no thresholds. The
      # hub's offline path returns a cache path without checking it exists, so
      # a removed cache entry lands here too.
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:invalid_thresholds_file, path, "cannot read file: #{inspect(reason)}"}}
    end
  end

  defp decode_type_thresholds(content, source) do
    case Jason.decode(content) do
      {:ok, decoded} ->
        case validate_type_thresholds(decoded) do
          {:ok, thresholds} -> {:ok, thresholds}
          {:error, detail} -> {:error, {:invalid_thresholds_file, source, detail}}
        end

      {:error, error} ->
        {:error, {:invalid_thresholds_file, source, Exception.message(error)}}
    end
  end

  defp validate_type_thresholds(decoded) when is_map(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn {name, value}, {:ok, thresholds} ->
      with {:ok, type} <- parse_threshold_type(name),
           {:ok, threshold} <- parse_threshold_value(type, value) do
        {:cont, {:ok, Map.put(thresholds, type, threshold)}}
      else
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
  end

  defp validate_type_thresholds(other) do
    {:error, "expected a JSON object of type:threshold pairs, got: #{inspect(other)}"}
  end

  defp parse_threshold_type(name) when is_binary(name) do
    type = String.to_existing_atom(name)

    if type in ShhAi.Config.supported_pii_types() do
      {:ok, type}
    else
      {:error, "unknown PII type #{inspect(name)}"}
    end
  rescue
    ArgumentError -> {:error, "unknown PII type #{inspect(name)}"}
  end

  defp parse_threshold_type(name), do: {:error, "unknown PII type #{inspect(name)}"}

  # JSON numbers arrive as integers or floats; store floats so callers compare
  # like with like. 0.0 is valid: training writes it when every grid threshold
  # was worse than argmax, and `above_threshold?/3` then keeps every entity.
  defp parse_threshold_value(_type, value) when is_number(value) and value >= 0 and value <= 1 do
    {:ok, value / 1}
  end

  defp parse_threshold_value(type, value) do
    {:error, "threshold for #{type} must be a number from 0 to 1, got: #{inspect(value)}"}
  end

  defp log_type_thresholds(_spec, thresholds) when map_size(thresholds) == 0 do
    Logger.info("NER model ships no per-type thresholds; using the global threshold")
  end

  defp log_type_thresholds(spec, thresholds) do
    Logger.info("Loading NER per-type thresholds from #{inspect(spec)}: #{inspect(thresholds)}")
  end

  defp config_ner_threshold do
    ShhAi.Config.pii_ner_confidence_threshold()
  end

  defp config_ner_type_thresholds do
    ShhAi.Config.pii_ner_type_thresholds()
  end

  defp config_ner_temperature do
    ShhAi.Config.pii_ner_temperature()
  end
end
