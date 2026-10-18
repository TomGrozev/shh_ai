defmodule ShhAi.Eval.HeldoutTest do
  @moduledoc """
  Unit tests for the held-out benchmark loader. These run offline against
  synthetic rows in the file's own shape (contract item 2).
  """

  # async: false — the path/docs cases mutate SHHAI_EVAL_CACHE_DIR, which is
  # process-global.
  use ExUnit.Case, async: false

  alias ShhAi.Eval.Heldout

  @line Jason.encode!(%{
          "id" => "h-1",
          "text" => "Email a@b.com from Paris.",
          "spans" => [
            %{"start" => 6, "end" => 13, "type" => "email"},
            %{"start" => 19, "end" => 24, "type" => "location"}
          ],
          "source" => "synthetic"
        })

  describe "parse_line/1" do
    test "extracts id, text and typed span annotations" do
      doc = Heldout.parse_line(@line)

      assert doc.id == "h-1"
      assert doc.text == "Email a@b.com from Paris."

      assert doc.annotations == [
               %{type: :email, start: 6, end: 13},
               %{type: :location, start: 19, end: 24}
             ]
    end

    test "a row with no spans (or no spans key) yields no annotations" do
      with_spans =
        Jason.encode!(%{"id" => "h-2", "text" => "plain", "spans" => [], "source" => "synthetic"})

      without_spans =
        Jason.encode!(%{"id" => "h-3", "text" => "plain", "source" => "synthetic"})

      assert Heldout.parse_line(with_spans).annotations == []
      assert Heldout.parse_line(without_spans).annotations == []
    end

    test "raises on a span type that is not a supported PII type" do
      line =
        Jason.encode!(%{
          "id" => "h-4",
          "text" => "x",
          "spans" => [%{"start" => 0, "end" => 1, "type" => "not_a_type"}],
          "source" => "synthetic"
        })

      assert_raise ArgumentError, ~r/expected a supported PII type/, fn ->
        Heldout.parse_line(line)
      end
    end
  end

  describe "path/0 and available?/0" do
    test "resolves heldout_v1.jsonl under SHHAI_EVAL_CACHE_DIR" do
      ShhAi.AuditCase.snapshot_env(["SHHAI_EVAL_CACHE_DIR"])
      dir = tmp_dir()
      System.put_env("SHHAI_EVAL_CACHE_DIR", dir)

      assert Heldout.path() == Path.join(dir, "heldout_v1.jsonl")
      refute Heldout.available?()

      File.write!(Heldout.path(), @line <> "\n")
      assert Heldout.available?()
    end

    test "treats an empty file as unavailable" do
      ShhAi.AuditCase.snapshot_env(["SHHAI_EVAL_CACHE_DIR"])
      dir = tmp_dir()
      System.put_env("SHHAI_EVAL_CACHE_DIR", dir)

      File.write!(Heldout.path(), "")
      refute Heldout.available?()
    end
  end

  describe "docs/0" do
    test "loads every non-empty JSONL line" do
      ShhAi.AuditCase.snapshot_env(["SHHAI_EVAL_CACHE_DIR"])
      dir = tmp_dir()
      System.put_env("SHHAI_EVAL_CACHE_DIR", dir)

      File.write!(Heldout.path(), "\n" <> @line <> "\n\n")

      assert [doc] = Heldout.docs()
      assert doc.id == "h-1"

      assert doc.annotations == [
               %{type: :email, start: 6, end: 13},
               %{type: :location, start: 19, end: 24}
             ]
    end
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "shh_ai_heldout_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
