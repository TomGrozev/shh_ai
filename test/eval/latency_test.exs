defmodule ShhAi.Eval.LatencyTest do
  @moduledoc """
  Detection-latency benchmark comparing the hybrid detector with NER on against
  regex-only detection, over a sample of real dataset documents.

  Excluded from the normal/CI run; run it with `mix test.eval`.
  """

  use ExUnit.Case

  @moduletag :eval
  @moduletag timeout: :infinity

  alias ShhAi.Eval.AI4Privacy
  alias ShhAi.Eval.Setup
  alias ShhAi.PII.Detector
  alias ShhAi.PII.NER

  @sample_size 25
  @sample_seed 7

  setup_all do
    # Model RAM added by the NER init (load + EXLA warm-up of every serving),
    # measured across `Setup.load!/0` — the point where `NER.init/0` runs. Both
    # figures are reported so the added footprint can be compared against the
    # shipped model (`PII_NER_MODEL`): OS RSS from /proc/self/status and the
    # BEAM's own total. When NER was already loaded by an earlier suite in the
    # same run the delta is ~0, and the notice says so.
    was_initialized = NER.initialized?()
    before = memory_snapshot()

    Setup.load!()

    if was_initialized do
      IO.puts("\n[ram] NER was already initialized before this suite; init cost not measured")
    else
      report_ram(before, memory_snapshot())
    end
  end

  test "NER-on vs NER-off detection latency" do
    inputs =
      AI4Privacy.docs(limit: @sample_size, seed: @sample_seed)
      |> Map.new(fn doc -> {to_string(doc.id), doc.text} end)

    Benchee.run(
      %{
        "ner_on" => fn text -> Detector.detect(text) end,
        "ner_off" => fn text -> Detector.detect(text, mode: :regex_only) end
      },
      inputs: inputs,
      warmup: 2,
      time: 10,
      memory_time: 0
    )
  end

  defp memory_snapshot do
    %{rss: vm_rss_bytes(), beam: :erlang.memory(:total)}
  end

  # VmRSS from /proc/self/status, in bytes; nil where /proc is unavailable
  # (non-Linux hosts), in which case only the BEAM total is reported.
  defp vm_rss_bytes do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/m, status) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  defp report_ram(before, after_) do
    IO.puts("""

    NER model RAM (after init + warm-up):
      OS RSS:     #{delta(after_.rss, before.rss)}
      BEAM total: #{delta(after_.beam, before.beam)}
    """)
  end

  defp delta(nil, _), do: "n/a"
  defp delta(after_, before), do: "#{mb(after_ - before)} MB (#{mb(before)} -> #{mb(after_)} MB)"

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
end
