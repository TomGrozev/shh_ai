defmodule ShhAi.Eval.AI4PrivacyTest do
  @moduledoc """
  Unit tests for the AI4Privacy dataset parsing and the detector→dataset label
  mapping. These run offline against synthetic rows in the dataset's own shape.
  """

  use ExUnit.Case, async: true

  alias ShhAi.Eval.AI4Privacy

  # The detector's PII type space (ShhAi.PII.Patterns.pii_type/0), restated here
  # as an independent source of truth for the mapping's range.
  @supported_types [
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
    :passport
  ]

  @line Jason.encode!(%{
          "id" => 123,
          "source_text" => "Email a@b.com for Optimization.",
          "privacy_mask" => [
            %{"value" => "a@b.com", "start" => 6, "end" => 13, "label" => "EMAIL"},
            %{"value" => "Optimization", "start" => 18, "end" => 30, "label" => "JOBAREA"}
          ],
          "span_labels" => "[[0, 6, \"O\"], [6, 13, \"EMAIL\"]]"
        })

  describe "parse_line/1" do
    test "extracts id, source text and raw annotations" do
      doc = AI4Privacy.parse_line(@line)

      assert doc.id == 123
      assert doc.text == "Email a@b.com for Optimization."

      assert doc.annotations == [
               %{label: "EMAIL", start: 6, end: 13, value: "a@b.com"},
               %{label: "JOBAREA", start: 18, end: 30, value: "Optimization"}
             ]
    end

    test "accepts a privacy_mask serialised as a JSON string" do
      line =
        Jason.encode!(%{
          "id" => 7,
          "source_text" => "Call 555-1234",
          "privacy_mask" => ~s([{"value":"555-1234","start":5,"end":13,"label":"PHONENUMBER"}])
        })

      assert [%{label: "PHONENUMBER", start: 5, end: 13}] =
               AI4Privacy.parse_line(line).annotations
    end
  end

  describe "map_annotations/1" do
    test "projects known labels onto ShhAi types and drops the rest" do
      annotations = [
        %{label: "EMAIL", start: 0, end: 5, value: "x"},
        %{label: "JOBAREA", start: 6, end: 9, value: "y"},
        %{label: "FIRSTNAME", start: 10, end: 14, value: "z"}
      ]

      assert AI4Privacy.map_annotations(annotations) == [
               %{type: :email, start: 0, end: 5},
               %{type: :name, start: 10, end: 14}
             ]
    end
  end

  describe "label_mapping/0" do
    test "maps only into the detector's type space" do
      assert Enum.all?(Map.values(AI4Privacy.label_mapping()), &(&1 in @supported_types))
    end

    test "covers the headline PII types" do
      types = AI4Privacy.mapped_types()

      assert MapSet.subset?(
               MapSet.new([
                 :name,
                 :email,
                 :phone,
                 :ssn,
                 :financial,
                 :ip_address,
                 :url,
                 :location,
                 :date
               ]),
               types
             )

      refute MapSet.member?(types, :organization)
    end
  end
end
