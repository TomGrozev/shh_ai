defmodule ShhAi.PII.NER do
  @moduledoc """
  NER-based PII detection using a fine-tuned RoBERTa model via Bumblebee.

  This module provides neural network-based PII detection using the
  MuhsinunC/pii-ner-roberta-base model from HuggingFace. It supports 12 PII entity types:

  - PERSON
  - EMAIL
  - PHONE
  - SSN
  - CREDIT_CARD
  - DATE
  - DATE_OF_BIRTH
  - ADDRESS
  - IP_ADDRESS
  - VIN (Vehicle Identification Number)
  - BITCOIN_WALLET
  - ORGANIZATION

  ## Architecture

  The module uses Nx.Serving for efficient batch processing and caching.
  The model is loaded once at startup and kept in memory for fast inference.

  ## Performance Considerations

  - Model is loaded once and cached in :persistent_term
  - Uses EXLA backend for optimized inference
  - Supports batched inference for multiple texts
  - Can be configured to run on CPU or GPU

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

  @model_repo "Xyren2005/pii-ner-roberta"

  # Mapping from NER model labels to our PII types
  # The model uses BIO tagging (B- for beginning, I- for inside)
  @ner_label_to_pii_type %{
    "PERSON" => :name,
    "EMAIL" => :email,
    "PHONE" => :phone,
    "SSN" => :ssn,
    "CREDIT_CARD" => :financial,
    "DATE" => :date,
    "DATE_OF_BIRTH" => :date,
    "ADDRESS" => :location,
    "IP_ADDRESS" => :ip_address,
    "VIN" => :vin,
    "BITCOIN_WALLET" => :financial,
    "ORGANIZATION" => :organization
  }

  @type detection :: %{
          type: atom(),
          value: String.t(),
          start_pos: non_neg_integer(),
          end_pos: non_neg_integer(),
          confidence: float(),
          description: String.t(),
          source: :ner
        }

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
    backend = Keyword.get(opts, :backend, EXLA.Backend)
    device = Keyword.get(opts, :device, :host)

    Logger.info("Loading NER model from #{@model_repo}...")

    # Set Nx global default backend
    Nx.global_default_backend(backend)

    # Load model and tokenizer
    with {:ok, model} <- Bumblebee.load_model({:hf, @model_repo}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, @model_repo}) do
      # Create serving for efficient inference
      serving = create_serving(model, tokenizer, device)

      # Store in persistent_term for fast access
      :persistent_term.put({__MODULE__, :serving}, serving)
      :persistent_term.put({__MODULE__, :tokenizer}, tokenizer)
      :persistent_term.put({__MODULE__, :initialized}, true)

      Logger.info("NER model loaded successfully")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to load NER model: #{inspect(reason)}")
        error
    end
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

  ## Options

    * `:confidence_threshold` - Minimum confidence (default: from config)
    * `:aggregation` - How to aggregate tokens (:same, :same_label, nil)
    * `:calibrate` - Whether to apply confidence calibration (default: true)

  ## Examples

      ShhAi.PII.NER.detect("My email is john@example.com")
      #=> [%{type: :email, value: "john@example.com", ...}]

  """
  @spec detect(text :: String.t(), opts :: keyword()) :: [detection()]
  def detect(text, opts \\ []) when is_binary(text) do
    unless initialized?() do
      raise "NER model not initialized. Call ShhAi.PII.NER.init/1 first."
    end

    serving = :persistent_term.get({__MODULE__, :serving})
    confidence_threshold = Keyword.get_lazy(opts, :confidence_threshold, &config_ner_threshold/0)
    calibrate? = Keyword.get(opts, :calibrate, true)
    temperature = Keyword.get_lazy(opts, :temperature, &config_ner_temperature/0)

    try do
      result = Nx.Serving.run(serving, text)

      # Extract entities from result
      detections =
        result
        |> extract_entities()
        |> Stream.map(&to_detection/1)
        |> maybe_calibrate_confidence(calibrate?, temperature)
        |> Enum.filter(&filter_by_confidence(&1, confidence_threshold))

      {:ok, detections}
    rescue
      e ->
        Logger.error("NER detection failed: #{inspect(e)}")
        {:error, :ner_detection_failed}
    end
  end

  # Private functions

  defp create_serving(model, tokenizer, device) do
    Bumblebee.Text.token_classification(
      model,
      tokenizer,
      aggregation: :same,
      compile: [batch_size: 1, sequence_length: 512],
      defn_options: [client: device]
    )
  end

  defp extract_entities(result) do
    # The token classification result contains entity predictions
    # Format: %{entities: [%{label: "B-PERSON", score: 0.95, start: 0, end: 5, word: "John"}, ...]}
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

  defp filter_by_confidence(%{score: score}, threshold) do
    score >= threshold
  end

  defp filter_by_confidence(%{confidence: confidence}, threshold) do
    confidence >= threshold
  end

  defp to_detection(entity) do
    %{label: label, phrase: phrase, start: start_pos, end: end_pos} = entity
    score = Map.get_lazy(entity, :score, fn -> Map.get(entity, :confidence, 0.9) end)

    # Extract base label (remove B- or I- prefix)
    base_label =
      label
      |> String.replace_prefix("B-", "")
      |> String.replace_prefix("I-", "")

    pii_type = Map.get(@ner_label_to_pii_type, base_label, :unknown)

    %{
      type: pii_type,
      value: String.trim(phrase),
      start_pos: start_pos,
      end_pos: end_pos,
      confidence: score,
      description: description_for_type(pii_type),
      source: :ner
    }
  end

  defp description_for_type(:name), do: "Person name (NER)"
  defp description_for_type(:email), do: "Email address (NER)"
  defp description_for_type(:phone), do: "Phone number (NER)"
  defp description_for_type(:ssn), do: "Social Security Number (NER)"
  defp description_for_type(:financial), do: "Financial/Credit card number (NER)"
  defp description_for_type(:date), do: "Date (NER)"
  defp description_for_type(:location), do: "Address/Location (NER)"
  defp description_for_type(:ip_address), do: "IP address (NER)"
  defp description_for_type(:vin), do: "Vehicle Identification Number (NER)"
  defp description_for_type(:organization), do: "Organization (NER)"
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

  defp config_ner_threshold do
    ShhAi.Config.pii_ner_confidence_threshold()
  end

  defp config_ner_temperature do
    ShhAi.Config.pii_ner_temperature()
  end
end
