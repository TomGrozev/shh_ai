defmodule ShhAi.TestSupport.Reporter do
  @moduledoc """
  Formats benchmark results for CI reporting.

  Provides GitHub-flavored markdown tables and JSON artifacts for
  performance test baselines and comparisons.
  """

  @type benchmark_result :: %{
          name: String.t(),
          average: float(),
          std_dev: float()
        }

  @type baseline_data :: %{String.t() => benchmark_result()}

  @doc """
  Detects whether the current terminal supports emoji rendering.

  Uses the following heuristics (in order):

    * `NO_COLOR` env var is set → no emoji
    * `CI` env var is set → no emoji
    * `TERM` env var is missing or contains `"dumb"` → no emoji
    * stdout is not a TTY → no emoji
    * Otherwise → emoji supported

  This check is fast and safe to call during test startup.
  """
  @spec supports_emoji?() :: boolean()
  def supports_emoji? do
    cond do
      System.get_env("NO_COLOR") -> false
      System.get_env("CI") -> false
      is_nil(System.get_env("TERM")) -> false
      String.contains?(System.get_env("TERM"), "dumb") -> false
      true -> stdout_tty?()
    end
  end

  @doc """
  Returns a status label (emoji or ASCII) for a given status atom.

  ## Parameters

    * `status` - `:ok`, `:warn`, or `:fail`
    * `opts` - Keyword list, accepts `:emoji` (defaults to `supports_emoji?/0`)

  ## Examples

      iex> Reporter.status_label(:ok)
      "✅"

      iex> Reporter.status_label(:ok, emoji: false)
      "[OK]"
  """
  @spec status_label(:ok | :warn | :fail, keyword()) :: String.t()
  def status_label(status, opts \\ []) do
    emoji = Keyword.get(opts, :emoji, supports_emoji?())
    format_status(status, emoji)
  end

  @doc """
  Formats a GitHub-flavored markdown comparison table.

  ## Parameters

    * `current_results` - List of benchmark results from the current run
    * `baseline_path` - Path to the baseline JSON file (may not exist)
    * `opts` - Optional keyword list, accepts `:emoji` (defaults to `supports_emoji?/0`)

  ## Returns

    A markdown string with the comparison table.
  """
  @spec format_markdown_table([benchmark_result()], String.t(), keyword()) :: String.t()
  def format_markdown_table(current_results, baseline_path, opts \\ []) do
    emoji = Keyword.get(opts, :emoji, supports_emoji?())
    baseline = load_baseline(baseline_path)

    header =
      "| Benchmark | Baseline Avg (μs) | Baseline StdDev | Current Avg (μs) | Current StdDev | % Change | Status |\n"

    separator = "|---|---|---|---|---|---|---|\n"

    rows =
      current_results
      |> Enum.map(&format_row(&1, baseline[&1.name], emoji))
      |> Enum.join("\n")

    header <> separator <> rows <> "\n"
  end

  @doc """
  Formats benchmark results as a terminal-friendly aligned table.

  Produces a fully boxed table with properly aligned columns. When
  `supports_emoji?/0` returns `true`, the table is rendered with rounded
  Unicode box-drawing characters (Esc library's `:rounded` style);
  otherwise, plain ASCII characters are used as a fallback. Use this
  format for terminal output; for GitHub-flavoured markdown, see
  `format_markdown_table/3`.

  ## Parameters

    * `current_results` - List of benchmark results from the current run
    * `baseline_path` - Path to the baseline JSON file (may not exist)
    * `opts` - Optional keyword list, accepts `:emoji` (defaults to `supports_emoji?/0`)

  ## Returns

    A string with the boxed comparison table.
  """
  @spec format_terminal_table([benchmark_result()], String.t(), keyword()) :: String.t()
  def format_terminal_table(current_results, baseline_path, opts \\ []) do
    emoji = Keyword.get(opts, :emoji, supports_emoji?())
    borders = border_chars(emoji)
    baseline = load_baseline(baseline_path)

    rows = Enum.map(current_results, &build_row_data(&1, baseline[&1.name], emoji))

    headers = [
      "Benchmark",
      "Baseline Avg (μs)",
      "Baseline StdDev",
      "Current Avg (μs)",
      "Current StdDev",
      "% Change",
      "Status"
    ]

    keys = [:name, :baseline_avg, :baseline_std, :current_avg, :current_std, :change_pct, :status]
    alignments = [:left, :right, :right, :right, :right, :right, :center]

    widths =
      Enum.zip([headers, keys, alignments])
      |> Enum.map(fn {header, key, _align} ->
        header_len = display_width(header)
        data_lens = Enum.map(rows, fn row -> display_width(row[key]) end)
        max_data = if data_lens == [], do: 0, else: Enum.max(data_lens)
        max(header_len, max_data) + 2
      end)

    top_border =
      build_border_line(widths, borders, borders.top_left, borders.top_t, borders.top_right)

    header_line = build_data_line(headers, widths, alignments, borders)
    separator = build_border_line(widths, borders, borders.left_t, borders.cross, borders.right_t)
    data_block = build_data_block(rows, keys, widths, alignments, borders)

    bottom_border =
      build_border_line(
        widths,
        borders,
        borders.bottom_left,
        borders.bottom_t,
        borders.bottom_right
      )

    parts =
      [top_border, header_line, separator, data_block, bottom_border]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, "\n") <> "\n"
  end

  @doc """
  Formats benchmark results as a JSON artifact.

  ## Parameters

    * `results` - List of benchmark results

  ## Returns

    A JSON-encoded string.
  """
  @spec format_json([benchmark_result()]) :: String.t()
  def format_json(results) do
    Jason.encode!(results)
  end

  # Private helpers

  defp border_chars(true) do
    %{
      top_left: "╭",
      top_right: "╮",
      bottom_left: "╰",
      bottom_right: "╯",
      horizontal: "─",
      vertical: "│",
      top_t: "┬",
      bottom_t: "┴",
      left_t: "├",
      right_t: "┤",
      cross: "┼"
    }
  end

  defp border_chars(false) do
    %{
      top_left: "+",
      top_right: "+",
      bottom_left: "+",
      bottom_right: "+",
      horizontal: "-",
      vertical: "|",
      top_t: "+",
      bottom_t: "+",
      left_t: "+",
      right_t: "+",
      cross: "+"
    }
  end

  defp build_border_line(widths, borders, left_corner, junction, right_corner) do
    segments = Enum.map(widths, fn w -> String.duplicate(borders.horizontal, w) end)
    left_corner <> Enum.join(segments, junction) <> right_corner
  end

  defp build_data_line(cells, widths, alignments, borders) do
    line =
      Enum.zip([cells, widths, alignments])
      |> Enum.map(fn {c, w, a} -> pad_cell(c, w, a) end)
      |> Enum.join(borders.vertical)

    borders.vertical <> line <> borders.vertical
  end

  defp build_data_block(rows, keys, widths, alignments, borders) do
    rows
    |> Enum.map(fn row ->
      Enum.zip([keys, widths, alignments])
      |> Enum.map(fn {k, w, a} -> pad_cell(row[k], w, a) end)
      |> Enum.join(borders.vertical)
      |> then(fn line -> borders.vertical <> line <> borders.vertical end)
    end)
    |> Enum.join("\n")
  end

  defp load_baseline(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) ->
            Map.new(list, fn %{"name" => name} = item ->
              {name, atomize_keys(item)}
            end)

          {:ok, data} when is_map(data) ->
            Map.new(data, fn {name, metrics} ->
              case metrics do
                %{"time" => time, "std_dev" => std_dev} ->
                  {name, %{average: time, std_dev: std_dev}}

                %{"time" => time} ->
                  {name, %{average: time, std_dev: 0.0}}

                _ ->
                  {name, nil}
              end
            end)

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp format_row(current, baseline, emoji) do
    name = current.name
    current_avg = format_number(current.average)
    current_std = format_number(current.std_dev)

    {baseline_avg, baseline_std, change_pct, status} =
      case baseline do
        nil ->
          {"N/A", "N/A", "N/A", format_status(:ok, emoji)}

        %{average: base_avg} ->
          change = calculate_percent_change(base_avg, current.average)
          status = change_status_label(change, emoji)

          {format_number(base_avg), format_number(baseline.std_dev), format_change(change),
           status}
      end

    "| #{name} | #{baseline_avg} | #{baseline_std} | #{current_avg} | #{current_std} | #{change_pct} | #{status} |"
  end

  defp calculate_percent_change(baseline, current) when baseline > 0 do
    (current - baseline) / baseline * 100.0
  end

  defp calculate_percent_change(_baseline, _current), do: 0.0

  defp change_status_label(change, emoji) do
    status =
      cond do
        change < 0 -> :ok
        change < 20 -> :ok
        change <= 50 -> :warn
        true -> :fail
      end

    format_status(status, emoji)
  end

  defp format_status(:ok, true), do: "✅"
  defp format_status(:ok, false), do: "[OK]"
  defp format_status(:warn, true), do: "⚠️"
  defp format_status(:warn, false), do: "[WARN]"
  defp format_status(:fail, true), do: "❌"
  defp format_status(:fail, false), do: "[FAIL]"

  defp stdout_tty? do
    case :io.columns(:standard_io) do
      {_, _} -> true
      _ -> false
    end
  end

  # Computes the visual (terminal column) width of a string.
  #
  # `String.length/1` counts Unicode codepoints, but emoji like ✅ (1 codepoint),
  # ❌ (1 codepoint), and ⚠️ (2 codepoints including the variation selector) all
  # display as 2 terminal columns. This helper accounts for:
  #
  #   * ASCII / Latin characters (< U+1100) → 1 column
  #   * Variation selectors (U+FE0E, U+FE0F) → 0 columns (zero-width)
  #   * Combining marks (U+0300..U+036F) → 0 columns (zero-width)
  #   * Everything else (emoji, CJK, etc.) → 2 columns
  defp display_width(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, acc ->
      cond do
        cp in 0xFE0E..0xFE0F -> acc
        cp in 0x0300..0x036F -> acc
        cp < 0x1100 -> acc + 1
        true -> acc + 2
      end
    end)
  end

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "N/A"

  defp format_change(change) when change > 0 do
    "+#{format_number(change)}%"
  end

  defp format_change(change) do
    "#{format_number(change)}%"
  end

  defp build_row_data(current, baseline, emoji) do
    name = current.name
    current_avg = format_number(current.average)
    current_std = format_number(current.std_dev)

    {baseline_avg, baseline_std, change_pct, status} =
      case baseline do
        nil ->
          {"N/A", "N/A", "N/A", format_status(:ok, emoji)}

        %{average: base_avg} ->
          change = calculate_percent_change(base_avg, current.average)
          status = change_status_label(change, emoji)

          {format_number(base_avg), format_number(baseline.std_dev), format_change(change),
           status}
      end

    %{
      name: name,
      baseline_avg: baseline_avg,
      baseline_std: baseline_std,
      current_avg: current_avg,
      current_std: current_std,
      change_pct: change_pct,
      status: status
    }
  end

  defp pad_cell(text, width, :left) do
    pad = width - display_width(text)
    " " <> text <> String.duplicate(" ", pad - 1)
  end

  defp pad_cell(text, width, :right) do
    pad = width - display_width(text)
    String.duplicate(" ", pad - 1) <> text <> " "
  end

  defp pad_cell(text, width, :center) do
    total_pad = width - display_width(text)
    left_pad = div(total_pad, 2)
    right_pad = total_pad - left_pad
    String.duplicate(" ", left_pad) <> text <> String.duplicate(" ", right_pad)
  end
end
