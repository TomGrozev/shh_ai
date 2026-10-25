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

  # A street-address regex match must not relabel an NER entity that covers the
  # same span: the NER span comes from sentence context the regex cannot see.
  # At a type conflict the higher-confidence detection wins, as it does for any
  # other overlapping pair after detection.
  test "keeps the NER type of an organization overlapped by a regex location" do
    ner_detection(NER, :organization, "387 Hills Dr", 8, 20, 0.95)

    text = "Ship to 387 Hills Dr, Riverview"

    assert [%{type: :organization, value: "387 Hills Dr", start_pos: 8, end_pos: 20}] =
             detect_with_organizations(text)
  end

  test "keeps the regex location when it outscores the overlapping NER entity" do
    ner_detection(NER, :organization, "387 Hills Dr", 8, 20, 0.75)

    text = "Ship to 387 Hills Dr, Riverview"

    assert [%{type: :location, value: "387 Hills Dr", start_pos: 8, end_pos: 20}] =
             detect_with_organizations(text)
  end

  # `:organization` is not in the product's default type allow-list, so the
  # caller must widen it (the held-out benchmark does the same).
  defp detect_with_organizations(text) do
    Detector.detect(text, types: ShhAi.Config.supported_pii_types())
  end

  defp ner_detection(ner, type, value, start_pos, end_pos, confidence) do
    :meck.new(ner, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(ner) end)
    :meck.expect(ner, :initialized?, fn -> true end)

    :meck.expect(ner, :detect, fn _text, _opts ->
      {:ok,
       [
         %{
           type: type,
           value: value,
           start_pos: start_pos,
           end_pos: end_pos,
           confidence: confidence,
           description: "Stubbed NER entity",
           source: :ner
         }
       ]}
    end)
  end
end
