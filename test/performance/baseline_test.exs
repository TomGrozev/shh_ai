defmodule ShhAi.Performance.BaselineTest do
  @moduledoc """
  Unit tests for `ShhAi.Performance.Baseline`.
  """

  use ExUnit.Case, async: true

  alias ShhAi.Performance.Baseline

  @tmp_dir ".perf/baselines_test"

  # Use a temporary directory so we don't dirty the real baselines.
  setup do
    old_env = Application.get_env(:shh_ai, :baseline_dir)
    Application.put_env(:shh_ai, :baseline_dir, @tmp_dir)

    on_exit(fn ->
      # Clean up any files we created during the test.
      File.rm_rf!(@tmp_dir)

      if old_env do
        Application.put_env(:shh_ai, :baseline_dir, old_env)
      else
        Application.delete_env(:shh_ai, :baseline_dir)
      end
    end)

    :ok
  end

  # ─── load_baseline/1 ───────────────────────────────────────────────────────

  describe "load_baseline/1" do
    test "returns {:ok, data} when baseline exists" do
      name = "test_baseline"
      data = %{"foo" => 1}
      :ok = Baseline.save_baseline(name, data)

      assert {:ok, loaded} = Baseline.load_baseline(name)
      assert loaded == data
    end

    test "returns {:error, :not_found} when baseline does not exist" do
      assert {:error, :not_found} = Baseline.load_baseline("nonexistent")
    end

    test "returns {:error, :not_found} for invalid json" do
      path = Path.join(@tmp_dir, "bad.json")
      File.mkdir_p!(@tmp_dir)
      File.write!(path, "not json")

      assert {:error, :not_found} = Baseline.load_baseline("bad")
    end
  end

  # ─── save_baseline/2 ───────────────────────────────────────────────────────

  describe "save_baseline/2" do
    test "creates .perf/baselines/ directory if needed" do
      # Ensure directory does not exist before saving
      File.rm_rf!(@tmp_dir)
      refute File.dir?(@tmp_dir)

      :ok = Baseline.save_baseline("new_baseline", %{"x" => 42})

      assert File.dir?(@tmp_dir)
      assert File.regular?(Path.join(@tmp_dir, "new_baseline.json"))
    end

    test "returns :ok on success" do
      assert :ok = Baseline.save_baseline("ok_baseline", %{"a" => 1})
    end

    test "pretty-prints json" do
      Baseline.save_baseline("pretty", %{"key" => "value"})
      {:ok, raw} = File.read(Path.join(@tmp_dir, "pretty.json"))

      assert raw =~ "\n"
      assert raw =~ "\"key\""
    end
  end

  # ─── compare/3 ─────────────────────────────────────────────────────────────

  describe "compare/3" do
    test "returns :ok for improvements" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 50}}

      assert :ok = Baseline.compare(current, baseline)
    end

    test "returns :ok for minor changes below threshold" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 119}}

      assert :ok = Baseline.compare(current, baseline)
    end

    test "returns :ok when current equals baseline" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 100}}

      assert :ok = Baseline.compare(current, baseline)
    end

    test "returns {:warn, diffs} for minor regressions (20–50%)" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 130}}

      assert {:warn, diffs} = Baseline.compare(current, baseline)
      assert [{"bench", 100, 130, 30.0}] = diffs
    end

    test "returns {:fail, diffs} for major regressions (>50%)" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 160}}

      assert {:fail, diffs} = Baseline.compare(current, baseline)
      assert [{"bench", 100, 160, 60.0}] = diffs
    end

    test "reports fail when any metric exceeds major threshold" do
      baseline = %{
        "fast" => %{"time" => 100},
        "slow" => %{"time" => 200}
      }

      current = %{
        "fast" => %{"time" => 130},   # 30%  → warn
        "slow" => %{"time" => 400}    # 100% → fail
      }

      assert {:fail, diffs} = Baseline.compare(current, baseline)
      # diffs should include both regressions, sorted descending by pct change
      assert [{"slow", 200, 400, 100.0}, {"fast", 100, 130, 30.0}] = diffs
    end

    test "ignores metrics not present in baseline" do
      baseline = %{"old" => %{"time" => 100}}
      current  = %{"new" => %{"time" => 900}}

      assert :ok = Baseline.compare(current, baseline)
    end

    test "ignores metrics not present in current" do
      baseline = %{"old" => %{"time" => 100}}
      current  = %{}

      assert :ok = Baseline.compare(current, baseline)
    end

    test "allows custom metric_key" do
      baseline = %{"bench" => %{"ips" => 100}}
      current  = %{"bench" => %{"ips" => 150}}

      # default key "time" is missing → no regression detected
      assert :ok = Baseline.compare(current, baseline)

      # With custom key it should detect the 50% regression
      assert {:warn, diffs} = Baseline.compare(current, baseline, metric_key: "ips")
      assert [{"bench", 100, 150, 50.0}] = diffs
    end

    test "allows custom thresholds" do
      baseline = %{"bench" => %{"time" => 100}}
      current  = %{"bench" => %{"time" => 130}}

      # Default thresholds: 30% → warn
      assert {:warn, _} = Baseline.compare(current, baseline)

      # Raise minor threshold above 30%
      assert :ok = Baseline.compare(current, baseline, minor_threshold: 0.35)
    end

    test "handles numeric values directly (not nested in map)" do
      baseline = %{"bench" => 100}
      current  = %{"bench" => 150}

      assert {:warn, diffs} = Baseline.compare(current, baseline)
      assert [{"bench", 100, 150, 50.0}] = diffs
    end

    test "handles zero baseline values gracefully" do
      baseline = %{"bench" => %{"time" => 0}}
      current  = %{"bench" => %{"time" => 100}}

      assert :ok = Baseline.compare(current, baseline)
    end
  end

  # ─── Round-trip ────────────────────────────────────────────────────────────

  describe "round-trip" do
    test "save then load produces identical data" do
      data = %{
        "sanitize_basic" => %{
          "time" => 12.34,
          "ips" => 80_991.1
        },
        "sanitize_many_pii" => %{
          "time" => 45.67,
          "ips" => 21_897.2
        }
      }

      :ok = Baseline.save_baseline("roundtrip", data)
      assert {:ok, loaded} = Baseline.load_baseline("roundtrip")

      assert loaded == data
    end
  end
end
