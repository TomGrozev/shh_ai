defmodule ShhAiWeb.DashboardLive.Components do
  use ShhAiWeb, :html

  alias Phoenix.LiveView.ColocatedHook

  # ── Formatting Helpers ──────────────────────────────────────────────

  @doc "Converts a provider atom to a human-readable string."
  def humanize_provider(:openai), do: "OpenAI"
  def humanize_provider(:anthropic), do: "Anthropic"
  def humanize_provider(:ollama), do: "Ollama"
  def humanize_provider(nil), do: "N/A"

  def humanize_provider(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.capitalize()

  @doc "Returns the success rate percentage from a stats map."
  def success_rate(%{requests_total: 0}), do: 0.0
  def success_rate(%{requests_success: success, requests_total: total}), do: success / total * 100

  @doc "Formats a numeric rate as a percentage string."
  def format_percentage(rate), do: "#{Float.round(rate, 1)}%"

  @doc "Returns a DaisyUI badge class for the given HTTP status code."
  def status_class(status) when is_integer(status) do
    cond do
      status >= 200 and status < 300 -> "badge-success"
      status >= 400 and status < 500 -> "badge-warning"
      status >= 500 -> "badge-error"
      true -> "badge-ghost"
    end
  end

  def status_class(_), do: "badge-ghost"

  @doc "Formats a microsecond timestamp as a relative time string (e.g. '5s ago')."
  def format_relative_time(ended_at) do
    diff = System.system_time(:microsecond) - ended_at

    cond do
      diff < 60_000_000 -> "#{div(diff, 1_000_000)}s ago"
      diff < 3_600_000_000 -> "#{div(diff, 60_000_000)}m ago"
      diff < 86_400_000_000 -> "#{div(diff, 3_600_000_000)}h ago"
      true -> "#{div(diff, 86_400_000_000)}d ago"
    end
  end

  @doc "Formats a microsecond timestamp as an absolute datetime string."
  def format_absolute_time(ended_at) do
    ended_at
    |> DateTime.from_unix!(:microsecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  @doc "Formats a provider atom using humanize_provider/1."
  def format_provider(nil), do: "N/A"
  def format_provider(provider) when is_atom(provider), do: humanize_provider(provider)
  def format_provider(provider), do: provider

  @doc "Formats a latency value in milliseconds."
  def format_latency(nil), do: "N/A"
  def format_latency(ms) when ms < 1000, do: "#{Float.round(ms, 1)}ms"
  def format_latency(ms), do: "#{Float.round(ms / 1000, 2)}s"

  @doc "Formats a PII type atom to a capitalized string."
  def format_pii_type(type), do: type |> Atom.to_string() |> String.capitalize()

  @doc "Formats a conversation ID to a short display string."
  def format_conversation_id(nil), do: "N/A"
  def format_conversation_id(id) when is_binary(id), do: String.slice(id, 0..7)

  @doc """
  Renders a statistics card with title, value, and icon.
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :subtext, :string, default: nil

  def stats_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm text-base-content/60">{@title}</p>
            <p class="text-2xl font-bold">{@value}</p>
            <p :if={@subtext} class="text-xs text-base-content/50 mt-1">{@subtext}</p>
          </div>
          <div class="text-primary">
            <.icon name={@icon} class="w-8 h-8" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a filter bar with provider, status, streaming, and time window filters.
  """
  attr :filters, :map, required: true
  attr :time_window, :atom, required: true
  attr :on_filter, :string, default: "filter"
  attr :on_time_window, :string, default: "set-time-window"

  def filter_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-3">
      <.form phx-change={@on_filter} for={%{}} class="flex flex-wrap items-end gap-3">
        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-server-stack-mini" class="h-3.5 w-3.5" /> Provider
          </span>
          <select name="provider" class="select select-sm">
            <option value="" selected={is_nil(@filters.provider)}>All</option>
            <option value="openai" selected={@filters.provider == :openai}>OpenAI</option>
            <option value="anthropic" selected={@filters.provider == :anthropic}>Anthropic</option>
            <option value="ollama" selected={@filters.provider == :ollama}>Ollama</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-signal-mini" class="h-3.5 w-3.5" /> Status
          </span>
          <select name="status" class="select select-sm">
            <option value="" selected={is_nil(@filters.status)}>All</option>
            <option value="success" selected={@filters.status == "success"}>Success</option>
            <option value="error" selected={@filters.status == "error"}>Error</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-arrows-pointing-out-mini" class="h-3.5 w-3.5" /> Type
          </span>
          <select name="streaming" class="select select-sm">
            <option value="" selected={is_nil(@filters.streaming)}>All</option>
            <option value="true" selected={@filters.streaming == true}>Streaming</option>
            <option value="false" selected={@filters.streaming == false}>Non-Streaming</option>
          </select>
        </label>
      </.form>

      <div class="flex items-center gap-1">
        <span class="text-xs font-medium opacity-60 mr-1">
          <.icon name="hero-clock-mini" class="h-3.5 w-3.5" /> Window
        </span>
        <input
          class="join-item btn btn-sm"
          type="radio"
          name="time-window"
          aria-label="1m"
          checked={@time_window == :minute}
          phx-click={@on_time_window}
          phx-value-window="minute"
        />
        <input
          class="join-item btn btn-sm"
          type="radio"
          name="time-window"
          aria-label="1h"
          checked={@time_window == :hour}
          phx-click={@on_time_window}
          phx-value-window="hour"
        />
        <input
          class="join-item btn btn-sm"
          type="radio"
          name="time-window"
          aria-label="24h"
          checked={@time_window == :day}
          phx-click={@on_time_window}
          phx-value-window="day"
        />
        <input
          class="join-item btn btn-sm"
          type="radio"
          name="time-window"
          aria-label="7d"
          checked={@time_window == :week}
          phx-click={@on_time_window}
          phx-value-window="week"
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a chart.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :key, :string, required: true

  def chart(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body pb-14">
        <h3 class="card-title text-lg mb-10">{@title}</h3>
        <div
          id={@id}
          data-key={@key}
          phx-hook=".ApexChart"
          phx-update="ignore"
          class="h-72 p-4 flex items-center justify-center"
        >
          <span class="text-sm italic">No Data</span>
        </div>
      </div>
    </div>
    <script :type={ColocatedHook} name=".ApexChart">
      export default {
        mounted() {
          let key = this.el.dataset.key;
          let chart = null;
          this.handleEvent("stats", data => {
            const hasAnyData = data[key].series.some(s => (Array.isArray(s.data) && s.data.length > 0) || typeof s === "number");
            if (hasAnyData) {
              if (chart == null) {
                this.el.innerHTML = "";
                chart = new window.ApexCharts(this.el, this.options(data[key]))
                chart.render()
              } else {
                chart.updateSeries(data[key].series);
              }
            } else if (chart !== null) {
              chart.destroy();
              chart = null;
              this.el.innerHTML = '<span class="text-sm italic">No Data</span>'
            }
          });
        },
        options(data) {
          let newData = {};
          if (data.chart.type == "area") { 
             newData = {
              fill: {
                type: "gradient",
                gradient: {
                  opacityFrom: 0.55,
                  opacityTo: 0,
                  shade: window.primaryColor,
                  gradientToColors: [window.primaryColor],
                }
              },
              stroke: {
                width: 6,
              },
            }
          } else if (data.chart.type == "bar") {
             newData = {
              plotOptions: {
                bar: {
                  horizontal: false,
                  columnWidth: "70%",
                  borderRadiusApplication: "end",
                  borderRadius: 8,
                },
              },
            }
          }
          return {...data, ...newData};
        }
      }
    </script>
    """
  end

  # ── Request Row Components ──────────────────────────────────────────

  @doc """
  Renders a single request row (desktop grid + mobile stacked layout).

  ## Attrs
    - `request` — the Event struct (required)
    - `id` — the stream/DOM id (required)
    - `toggle_action` — a `Phoenix.LiveView.JS` struct for expanding details, or nil
    - `show_conversation_link` — whether to render the conversation column (default: true)
    - `show_field_labels` — show small grey labels above values (default: false)
  """
  attr :request, :map, required: true
  attr :id, :string, required: true
  attr :toggle_action, :any, default: nil
  attr :show_conversation_link, :boolean, default: true
  attr :show_field_labels, :boolean, default: false

  def request_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="cursor-pointer hover:bg-base-300 rounded-lg"
      phx-click={@toggle_action}
    >
      <%!-- Desktop grid --%>
      <div class={[
        "hidden md:grid gap-2 p-4 items-center",
        if(@show_conversation_link,
          do: "md:grid-cols-[0.5fr_2fr_1fr_1fr_0.5fr_0.5fr_0.5fr_0.5fr]",
          else: "md:grid-cols-[0.5fr_2fr_1fr_1fr_0.5fr_0.5fr_0.5fr]"
        )
      ]}>
        <div class="text-sm">
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Time</span>
          <span class="tooltip" data-tip={format_absolute_time(@request.ended_at)}>
            {format_relative_time(@request.ended_at)}
          </span>
        </div>
        <div class="truncate">
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Path</span>
          {@request.request_path}
        </div>
        <div>
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Provider</span>
          <span class="badge badge-sm badge-primary">
            {format_provider(@request.target_provider)}
          </span>
        </div>
        <div>
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Status</span>
          <span class={["badge badge-sm", status_class(@request.status)]}>
            {@request.status || "N/A"}
          </span>
        </div>
        <div class="text-sm">
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Latency</span>
          {format_latency(@request.duration_ms)}
        </div>
        <div>
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">PII</span>
          <span :if={@request.pii_detected_count > 0} class="badge badge-sm badge-secondary">
            {@request.pii_detected_count}
          </span>
          <span :if={@request.pii_detected_count <= 0} class="text-base-content/30">-</span>
        </div>
        <div :if={@show_conversation_link}>
          <span :if={@show_field_labels} class="text-xs text-base-content/50 block">Conv.</span>
          <span :if={@request.conversation_id} class="tooltip" data-tip={@request.conversation_id}>
            <button
              class="badge badge-sm badge-outline cursor-pointer hover:bg-base-300"
              phx-click="set-view"
              phx-value-view="conversations"
              phx-value-conversation-id={@request.conversation_id}
            >
              {format_conversation_id(@request.conversation_id)}
            </button>
          </span>
          <span :if={is_nil(@request.conversation_id)} class="text-base-content/30">N/A</span>
        </div>
        <div>
          <button
            id={"chevron-#{@id}"}
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.icon
              name="hero-chevron-down"
              class="w-4 h-4 transition-transform duration-200"
            />
          </button>
        </div>
      </div>

      <%!-- Mobile stacked layout --%>
      <div class="md:hidden flex flex-col gap-3 p-4">
        <div>
          <div class="flex items-center gap-2 mb-1">
            <span class="text-sm font-medium truncate leading-tight">
              {@request.request_path}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <span class="badge badge-sm badge-primary">
              {format_provider(@request.target_provider)}
            </span>
            <span class={["badge badge-sm", status_class(@request.status)]}>
              {@request.status || "N/A"}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2 flex-wrap text-sm text-base-content/50">
          <span class="tooltip" data-tip={format_absolute_time(@request.ended_at)}>
            {format_relative_time(@request.ended_at)}
          </span>
          <span>·</span>
          <span>{format_latency(@request.duration_ms)}</span>
          <span :if={@show_conversation_link and @request.conversation_id}>·</span>
          <span :if={@show_conversation_link and @request.conversation_id}>
            <button
              class="badge badge-sm badge-outline cursor-pointer hover:bg-base-300"
              phx-click="set-view"
              phx-value-view="conversations"
              phx-value-conversation-id={@request.conversation_id}
            >
              {format_conversation_id(@request.conversation_id)}
            </button>
          </span>
          <span :if={@request.pii_detected_count > 0}>·</span>
          <span :if={@request.pii_detected_count > 0} class="badge badge-sm badge-secondary">
            {@request.pii_detected_count}
          </span>
          <button
            id={"chevron-#{@id}"}
            class="btn btn-ghost btn-sm btn-circle ml-auto !gap-0"
          >
            <.icon
              name="hero-chevron-down"
              class="w-4 h-4 transition-transform duration-200"
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the expanded detail panel for a request row.

  ## Attrs
    - `request` — the Event struct (required)
    - `id` — DOM id for the details container (required)
  """
  attr :request, :map, required: true
  attr :id, :string, required: true

  def request_row_detail(assigns) do
    ~H"""
    <div id={@id} class="hidden p-4">
      <div class="border-t border-base-300 pt-3 space-y-2">
        <div>
          <p class="text-xs font-semibold text-base-content/60">Request ID</p>
          <p class="font-mono text-sm break-all">{@request.id}</p>
        </div>
        <div class="border-t border-base-200 pt-2">
          <p class="text-xs font-semibold text-base-content/60">Source API type</p>
          <p class="text-sm">{format_provider(@request.source_provider)}</p>
        </div>
        <div class="border-t border-base-200 pt-2">
          <p class="text-xs font-semibold text-base-content/60">Streaming</p>
          <p class="text-sm">{if @request.streaming, do: "Yes", else: "No"}</p>
        </div>
        <div class="border-t border-base-200 pt-2">
          <p class="text-xs font-semibold text-base-content/60 mb-2">Timing Breakdown</p>
          <div class="flex flex-col justify-around space-y-2 md:grid md:grid-cols-2 md:gap-2 md:space-y-0">
            <div class="bg-base-200 p-2 rounded">
              <span class="text-xs text-base-content/60 block">PII</span>
              <p class="font-mono text-sm">{format_latency(@request.timings.pii_ms)}</p>
            </div>
            <div class="bg-base-200 p-2 rounded">
              <span class="text-xs text-base-content/60 block">Backend</span>
              <p class="font-mono text-sm">
                {format_latency(@request.timings.backend_ms)}
              </p>
            </div>
            <div class="bg-base-200 p-2 rounded">
              <span class="text-xs text-base-content/60 block">Restore</span>
              <p class="font-mono text-sm">
                {format_latency(@request.timings.restore_ms)}
              </p>
            </div>
            <div class="bg-base-200 p-2 rounded">
              <span class="text-xs text-base-content/60 block">Src Conv</span>
              <p class="font-mono text-sm">
                {format_latency(@request.timings.source_conversion_ms)}
              </p>
            </div>
            <div class="bg-base-200 p-2 rounded">
              <span class="text-xs text-base-content/60 block">Tgt Conv</span>
              <p class="font-mono text-sm">
                {format_latency(@request.timings.target_conversion_ms)}
              </p>
            </div>
          </div>
        </div>
        <div
          :if={not Enum.empty?(@request.pii_types)}
          class="border-t border-base-200 pt-2"
        >
          <p class="text-xs font-semibold text-base-content/60">PII Types Detected</p>
          <div class="flex flex-wrap gap-1 mt-1">
            <span :for={type <- @request.pii_types} class="badge badge-sm badge-outline">
              {format_pii_type(type)}
            </span>
          </div>
        </div>
        <div :if={@request.error} class="border-t border-base-200 pt-2">
          <p class="text-xs font-semibold text-error">Error</p>
          <pre class="bg-base-300 p-2 rounded text-xs mt-1 overflow-x-auto break-all whitespace-pre-wrap">{Jason.encode!(@request.error, pretty: true)}</pre>
        </div>
      </div>
    </div>
    """
  end
end
