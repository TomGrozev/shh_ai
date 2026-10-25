defmodule ShhAi.Eval.ScorerTest do
  @moduledoc """
  Unit tests for the span+type scorer used by the detection benchmark.

  The expected numbers are hand-computed from the worked example below, not
  derived from the scorer, so a regression in the matching or aggregation logic
  shows up as a disagreement.
  """

  use ExUnit.Case, async: true

  alias ShhAi.Eval.Scorer

  describe "matches?/2" do
    test "is true for overlapping spans of the same type" do
      prediction = %{type: :email, start: 0, end: 11}
      gold = %{type: :email, start: 2, end: 11}

      assert Scorer.matches?(prediction, gold)
    end

    test "is false when the types differ" do
      prediction = %{type: :phone, start: 0, end: 11}
      gold = %{type: :email, start: 0, end: 11}

      refute Scorer.matches?(prediction, gold)
    end

    test "is false for disjoint or merely adjacent spans" do
      gold = %{type: :email, start: 10, end: 20}

      refute Scorer.matches?(%{type: :email, start: 0, end: 10}, gold)
      refute Scorer.matches?(%{type: :email, start: 20, end: 30}, gold)
    end
  end

  describe "score/1" do
    # Two documents:
    #
    #   1. gold:   email[0,11], phone[20,32]
    #      pred:   email[0,11], name[5,9]
    #   2. gold:   name[0,4]
    #      pred:   name[0,4], email[10,20]
    #
    # email: tp 1, fp 1, fn 0
    # name:  tp 1, fp 1, fn 0
    # phone: tp 0, fp 0, fn 1
    setup do
      docs = [
        %{
          gold: [%{type: :email, start: 0, end: 11}, %{type: :phone, start: 20, end: 32}],
          predicted: [%{type: :email, start: 0, end: 11}, %{type: :name, start: 5, end: 9}]
        },
        %{
          gold: [%{type: :name, start: 0, end: 4}],
          predicted: [%{type: :name, start: 0, end: 4}, %{type: :email, start: 10, end: 20}]
        }
      ]

      %{result: Scorer.score(docs)}
    end

    test "counts a one-to-one overlapping same-type match as a true positive", %{result: result} do
      assert %{tp: 1, fp: 1, fn: 0, precision: 0.5, recall: 1.0} = result.per_type.email
      assert_in_delta result.per_type.email.f1, 2 / 3, 1.0e-9

      assert result.per_type.name.tp == 1
      assert result.per_type.phone == %{tp: 0, fp: 0, fn: 1, precision: 0.0, recall: 0.0, f1: 0.0}
    end

    test "reports micro-averaged precision, recall and F1 as the headline", %{result: result} do
      assert result.micro.tp == 2
      assert result.micro.fp == 2
      assert result.micro.fn == 1
      assert_in_delta result.micro.precision, 0.5, 1.0e-9
      assert_in_delta result.micro.recall, 2 / 3, 1.0e-9
      assert_in_delta result.micro.f1, 0.5714285714, 1.0e-9
    end

    test "reports a macro average over the types present", %{result: result} do
      assert_in_delta result.macro.precision, 1 / 3, 1.0e-9
      assert_in_delta result.macro.recall, 2 / 3, 1.0e-9
      assert_in_delta result.macro.f1, 0.4444444444, 1.0e-9
    end

    test "consumes each gold annotation at most once" do
      docs = [
        %{
          gold: [%{type: :email, start: 0, end: 5}, %{type: :email, start: 10, end: 15}],
          predicted: [%{type: :email, start: 0, end: 5}]
        }
      ]

      result = Scorer.score(docs)

      assert result.micro.tp == 1
      assert result.micro.fn == 1
      assert result.micro.fp == 0
    end

    test "returns zeroed metrics for an empty run" do
      assert Scorer.score([]) == %{
               micro: %{tp: 0, fp: 0, fn: 0, precision: 0.0, recall: 0.0, f1: 0.0},
               macro: %{precision: 0.0, recall: 0.0, f1: 0.0},
               per_type: %{}
             }
    end
  end

  describe "neutral ranges" do
    # gold: name[0,4]. The neutral range covers the QUASI mention "Warsaw" at
    # [10,16]. Two unmatched predictions: organization[10,16] inside the
    # neutral range, email[20,30] outside it.
    test "an unmatched prediction inside a neutral range is not a false positive" do
      inside = %{
        gold: [%{type: :name, start: 0, end: 4}],
        predicted: [%{type: :name, start: 0, end: 4}, %{type: :organization, start: 10, end: 16}],
        neutral: [{10, 16}]
      }

      inside_result = Scorer.score([inside])

      assert %{tp: 1, fp: 0, fn: 0, precision: 1.0, recall: 1.0} = inside_result.micro
      refute Map.has_key?(inside_result.per_type, :organization)

      outside = %{
        gold: [%{type: :name, start: 0, end: 4}],
        predicted: [%{type: :name, start: 0, end: 4}, %{type: :email, start: 20, end: 30}],
        neutral: [{10, 16}]
      }

      outside_result = Scorer.score([outside])

      assert %{tp: 1, fp: 1, fn: 0, precision: 0.5, recall: 1.0} = outside_result.micro
      assert %{tp: 0, fp: 1, fn: 0} = outside_result.per_type.email
    end

    test "a neutral range never turns a gold overlap into a dropped prediction" do
      # The prediction matches gold, so it is a TP even though its tail reaches
      # the neutral range's start; builder output never overlaps the two.
      doc = %{
        gold: [%{type: :name, start: 0, end: 6}],
        predicted: [%{type: :name, start: 0, end: 6}],
        neutral: [{4, 9}]
      }

      assert %{tp: 1, fp: 0, fn: 0} = Scorer.score([doc]).micro
    end

    test "a document without a neutral key scores as before" do
      doc = %{
        gold: [%{type: :name, start: 0, end: 4}],
        predicted: [%{type: :email, start: 10, end: 20}]
      }

      assert %{tp: 0, fp: 1, fn: 1} = Scorer.score([doc]).micro
    end
  end

  describe "score_by_source/1" do
    # Two sources with different annotation policies:
    #
    #   tab     gold: name[0,4]
    #           pred: name[0,4], location[10,15], date[20,30]
    #   gretel  gold: email[0,11], name[20,24]
    #           pred: email[0,11], name[5,9], name[20,24]
    #
    # Restricted: tab scores name only (tp 1, fp 0); gretel scores email and
    # name, so name[5,9] stays an FP (tp 2, fp 1).
    # Pooled: tp 3, fp 1, fn 0.
    setup do
      docs = [
        %{
          source: "tab",
          gold: [%{type: :name, start: 0, end: 4}],
          predicted: [
            %{type: :name, start: 0, end: 4},
            %{type: :location, start: 10, end: 15},
            %{type: :date, start: 20, end: 30}
          ]
        },
        %{
          source: "gretel",
          gold: [%{type: :email, start: 0, end: 11}, %{type: :name, start: 20, end: 24}],
          predicted: [
            %{type: :email, start: 0, end: 11},
            %{type: :name, start: 5, end: 9},
            %{type: :name, start: 20, end: 24}
          ]
        }
      ]

      {overall, per_source} = Scorer.score_by_source(docs)
      %{overall: overall, per_source: per_source}
    end

    test "a source is not charged for a type its gold does not cover", %{
      per_source: per_source
    } do
      assert %{tp: 1, fp: 0, fn: 0, precision: 1.0, recall: 1.0} = per_source["tab"].micro
      assert Map.keys(per_source["tab"].per_type) == [:name]

      assert %{tp: 2, fp: 1, fn: 0, recall: 1.0} = per_source["gretel"].micro
      assert_in_delta per_source["gretel"].micro.precision, 2 / 3, 1.0e-9
    end

    test "the headline pools the documents projected onto their source's types", %{
      overall: overall
    } do
      assert %{tp: 3, fp: 1, fn: 0} = overall.micro
      assert %{tp: 2, fp: 1, fn: 0} = overall.per_type.name
      assert %{tp: 1, fp: 0, fn: 0} = overall.per_type.email
      refute Map.has_key?(overall.per_type, :location)
      refute Map.has_key?(overall.per_type, :date)
    end

    test "covered_types/1 returns the types of the gold annotations" do
      gold = [%{type: :name, start: 0, end: 4}, %{type: :organization, start: 5, end: 9}]

      assert Scorer.covered_types(gold) == MapSet.new([:name, :organization])
      assert Scorer.covered_types([]) == MapSet.new()
    end
  end
end
