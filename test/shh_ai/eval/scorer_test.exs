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
end
