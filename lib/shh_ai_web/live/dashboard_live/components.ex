defmodule ShhAiWeb.DashboardLive.Components do
  use ShhAiWeb, :html

  alias Phoenix.LiveView.ColocatedHook

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
end
