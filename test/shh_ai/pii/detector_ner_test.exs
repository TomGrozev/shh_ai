defmodule ShhAi.PII.DetectorNERTest do
  # Not async: :meck replaces ShhAi.PII.NER VM-wide, so every concurrently
  # running test would see the stubbed NER as loaded and get its detections.
  use ExUnit.Case, async: false

  alias ShhAi.PII.{Detector, NER, Patterns}

  setup_all do
    ShhAi.Config.load()
    Patterns.load_into_persistent_term()
    :ok
  end

  # NER.detect/2 already filters by the NER threshold. The detector must not
  # lower an unconfirmed NER hit's confidence afterwards, or the threshold stops
  # being a floor on the model's score. NER is stubbed because the test env runs
  # with NER off (config/test.exs), so the model is never loaded.
  test "returns unconfirmed NER hits with their NER confidence, never lowered" do
    confidence = min(ShhAi.Config.pii_ner_confidence_threshold() + 0.05, 0.99)

    :meck.new(NER, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(NER) end)
    :meck.expect(NER, :initialized?, fn -> true end)

    :meck.expect(NER, :detect, fn _text, _opts ->
      {:ok,
       [
         %{
           type: :location,
           value: "Paris",
           start_pos: 0,
           end_pos: 5,
           confidence: confidence,
           description: "Address/Location (NER)",
           source: :ner
         }
       ]}
    end)

    assert [%{type: :location, confidence: ^confidence, source: :ner}] =
             Detector.detect("Paris")
  end
end
