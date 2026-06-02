defmodule ShhAi.TestSupport.ReporterTest do
  use ExUnit.Case, async: true

  alias ShhAi.TestSupport.Reporter

  describe "format_markdown_table/2" do
    test "produces a valid markdown table with all required columns" do
      results = [
        %{name: "sanitize_basic", average: 1_000.0, std_dev: 50.0},
        %{name: "sanitize_large", average: 5_000.0, std_dev: 200.0}
      ]

      # No baseline file — treat everything as new
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.rm(path)

      markdown = Reporter.format_markdown_table(results, path)

      assert markdown =~ "| Benchmark | Baseline Avg"
      assert markdown =~ "sanitize_basic"
      assert markdown =~ "sanitize_large"
      assert markdown =~ "N/A"
      assert markdown =~ "✅"
    end

    test "calculates percent change and correct status emoji" do
      results = [
        %{name: "bench_a", average: 1_000.0, std_dev: 50.0},
        %{name: "bench_b", average: 1_200.0, std_dev: 60.0},
        %{name: "bench_c", average: 1_600.0, std_dev: 80.0},
        %{name: "bench_d", average: 800.0, std_dev: 40.0}
      ]

      baseline = [
        %{"name" => "bench_a", "average" => 1_000.0, "std_dev" => 50.0},
        %{"name" => "bench_b", "average" => 1_000.0, "std_dev" => 50.0},
        %{"name" => "bench_c", "average" => 1_000.0, "std_dev" => 50.0},
        %{"name" => "bench_d", "average" => 1_000.0, "std_dev" => 50.0}
      ]

      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)

      lines = String.split(markdown, "\n", trim: true)
      data_lines = Enum.reject(lines, &String.starts_with?(&1, ["| Benchmark", "|---"]))

      # bench_a: 0% change → ✅
      bench_a_line = Enum.find(data_lines, &String.contains?(&1, "bench_a"))
      assert bench_a_line =~ "✅"
      assert bench_a_line =~ "0.00%"

      # bench_b: +20% → ⚠️
      bench_b_line = Enum.find(data_lines, &String.contains?(&1, "bench_b"))
      assert bench_b_line =~ "⚠️"
      assert bench_b_line =~ "+20.00%"

      # bench_c: +60% → ❌
      bench_c_line = Enum.find(data_lines, &String.contains?(&1, "bench_c"))
      assert bench_c_line =~ "❌"
      assert bench_c_line =~ "+60.00%"

      # bench_d: -20% (improvement) → ✅
      bench_d_line = Enum.find(data_lines, &String.contains?(&1, "bench_d"))
      assert bench_d_line =~ "✅"
      assert bench_d_line =~ "-20.00%"
    end

    test "handles missing baseline file gracefully" do
      results = [%{name: "new_bench", average: 100.0, std_dev: 10.0}]
      markdown = Reporter.format_markdown_table(results, "/nonexistent/baseline.json")

      assert markdown =~ "new_bench"
      assert markdown =~ "N/A"
      assert markdown =~ "✅"
    end

    test "handles new benchmarks not present in baseline" do
      results = [%{name: "new_bench", average: 100.0, std_dev: 10.0}]

      baseline = [%{"name" => "old_bench", "average" => 50.0, "std_dev" => 5.0}]
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)

      assert markdown =~ "new_bench"
      assert markdown =~ "N/A"
      assert markdown =~ "✅"
    end

    test "table is valid GitHub-flavored markdown" do
      results = [%{name: "x", average: 1.0, std_dev: 0.1}]
      # No baseline file — treat everything as new
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.rm(path)

      markdown = Reporter.format_markdown_table(results, path)
      lines = String.split(markdown, "\n", trim: true)

      assert length(lines) >= 3
      assert hd(lines) =~ "| Benchmark | Baseline Avg"
      assert Enum.at(lines, 1) =~ "|---|---|---|---|---|---|---|"
      assert Enum.at(lines, 2) =~ "| x |"
    end
  end

  describe "format_json/1" do
    test "produces valid parseable JSON" do
      results = [
        %{name: "sanitize_basic", average: 1_000.0, std_dev: 50.0},
        %{name: "sanitize_large", average: 5_000.0, std_dev: 200.0}
      ]

      json = Reporter.format_json(results)
      decoded = Jason.decode!(json)

      assert length(decoded) == 2
      [first, second] = decoded
      assert first["name"] == "sanitize_basic"
      assert first["average"] == 1_000.0
      assert first["std_dev"] == 50.0
      assert second["name"] == "sanitize_large"
    end

    test "handles empty results" do
      json = Reporter.format_json([])
      assert Jason.decode!(json) == []
    end

    test "round-trip preserves data" do
      results = [%{name: "bench", average: 123.45, std_dev: 6.78}]
      json = Reporter.format_json(results)
      decoded = Jason.decode!(json)
      [item] = decoded
      assert item["name"] == "bench"
      assert item["average"] == 123.45
      assert item["std_dev"] == 6.78
    end
  end

  describe "status emoji thresholds" do
    test "improvement shows ✅" do
      results = [%{name: "faster", average: 800.0, std_dev: 10.0}]
      baseline = [%{"name" => "faster", "average" => 1_000.0, "std_dev" => 10.0}]
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)
      assert markdown =~ "✅"
      assert markdown =~ "-20.00%"
    end

    test "<20% slowdown shows ✅" do
      results = [%{name: "almost_same", average: 1_190.0, std_dev: 10.0}]
      baseline = [%{"name" => "almost_same", "average" => 1_000.0, "std_dev" => 10.0}]
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)
      assert markdown =~ "✅"
      assert markdown =~ "+19.00%"
    end

    test "20-50% slowdown shows ⚠️" do
      results = [%{name: "slower", average: 1_500.0, std_dev: 10.0}]
      baseline = [%{"name" => "slower", "average" => 1_000.0, "std_dev" => 10.0}]
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)
      assert markdown =~ "⚠️"
      assert markdown =~ "+50.00%"
    end

    test ">50% slowdown shows ❌" do
      results = [%{name: "much_slower", average: 1_600.0, std_dev: 10.0}]
      baseline = [%{"name" => "much_slower", "average" => 1_000.0, "std_dev" => 10.0}]
      path = Path.join(System.tmp_dir!(), "shh_ai_test_baseline_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(baseline))

      markdown = Reporter.format_markdown_table(results, path)
      assert markdown =~ "❌"
      assert markdown =~ "+60.00%"
    end
  end
end
