defmodule ShhAiWeb.DashboardLive.Components do
  use ShhAiWeb, :html

  alias Phoenix.LiveView.ColocatedHook

  # ── Formatting Helpers ──────────────────────────────────────────────

  @doc "Converts a provider atom to a human-readable string."
  def humanize_provider(:openai), do: "OpenAI"
  def humanize_provider(:anthropic), do: "Anthropic"
  def humanize_provider(:ollama), do: "Ollama"
  def humanize_provider(nil), do: "N/A"

  def humanize_provider("openai"), do: "OpenAI"
  def humanize_provider("anthropic"), do: "Anthropic"
  def humanize_provider("ollama"), do: "Ollama"
  def humanize_provider(string) when is_binary(string), do: String.capitalize(string)

  def humanize_provider(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.capitalize()

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

  @doc "Returns a text color class for the given HTTP status code."
  def status_text_class(status) when is_integer(status) do
    cond do
      status >= 200 and status < 300 -> "text-success"
      status >= 400 and status < 500 -> "text-warning"
      status >= 500 -> "text-error"
      true -> "text-base-content/50"
    end
  end

  def status_text_class(_), do: "text-base-content/50"

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
    <div class="card card-border bg-base-200">
      <div class="card-body p-5">
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm text-base-content/60">{@title}</p>
            <p class="text-2xl font-semibold text-base-content">{@value}</p>
            <p :if={@subtext} class="text-xs text-base-content/50 mt-1">{@subtext}</p>
          </div>
          <div class="text-base-content/40">
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
  attr :phx_target, :any, default: nil

  def filter_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-3">
      <.form
        phx-change={@on_filter}
        phx-target={@phx_target}
        for={%{}}
        class="flex flex-wrap items-end gap-3"
      >
        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-server-stack-mini" class="h-3.5 w-3.5" /> Provider
          </span>
          <select name="provider" class="select select-sm">
            <option value="" selected={is_nil(@filters[:provider])}>All</option>
            <option value="openai" selected={@filters[:provider] == :openai}>OpenAI</option>
            <option value="anthropic" selected={@filters[:provider] == :anthropic}>Anthropic</option>
            <option value="ollama" selected={@filters[:provider] == :ollama}>Ollama</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-signal-mini" class="h-3.5 w-3.5" /> Status
          </span>
          <select name="status" class="select select-sm">
            <option value="" selected={is_nil(@filters[:status])}>All</option>
            <option value="success" selected={@filters[:status] == "success"}>Success</option>
            <option value="error" selected={@filters[:status] == "error"}>Error</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-arrows-pointing-out-mini" class="h-3.5 w-3.5" /> Type
          </span>
          <select name="streaming" class="select select-sm">
            <option value="" selected={is_nil(@filters[:streaming])}>All</option>
            <option value="true" selected={@filters[:streaming] == true}>Streaming</option>
            <option value="false" selected={@filters[:streaming] == false}>Non-Streaming</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-shield-check-mini" class="h-3.5 w-3.5" /> Has PII
          </span>
          <select name="has_pii" class="select select-sm">
            <option value="" selected={is_nil(@filters[:has_pii])}>All</option>
            <option value="true" selected={@filters[:has_pii] == true}>Yes</option>
            <option value="false" selected={@filters[:has_pii] == false}>No</option>
          </select>
        </label>

        <label class="fieldset">
          <span class="fieldset-label text-xs font-medium opacity-60">
            <.icon name="hero-no-symbol-mini" class="h-3.5 w-3.5" /> Opt-out
          </span>
          <select name="opted_out" class="select select-sm">
            <option value="" selected={is_nil(@filters[:opted_out])}>All</option>
            <option value="true" selected={@filters[:opted_out] == true}>Yes</option>
            <option value="false" selected={@filters[:opted_out] == false}>No</option>
          </select>
        </label>
      </.form>

      <label class="fieldset">
        <span class="fieldset-label text-xs font-medium opacity-60">
          <.icon name="hero-clock-mini" class="h-3.5 w-3.5" /> Window
        </span>
        <select
          name="time_window"
          class="select select-sm"
          phx-change={@on_time_window}
          phx-target={@phx_target}
        >
          <option value="minute" selected={@time_window == :minute}>1 minute</option>
          <option value="hour" selected={@time_window == :hour}>1 hour</option>
          <option value="day" selected={@time_window == :day}>24 hours</option>
          <option value="week" selected={@time_window == :week}>7 days</option>
        </select>
      </label>
    </div>
    """
  end

  # ── Conversations Queue Components ─────────────────────────────────

  @doc "Returns Tailwind classes for the provider color tab."
  def provider_tab_class(:openai), do: "w-1 flex-shrink-0 bg-info"
  def provider_tab_class(:anthropic), do: "w-1 flex-shrink-0 bg-primary"
  def provider_tab_class(:ollama), do: "w-1 flex-shrink-0 bg-secondary"
  def provider_tab_class("openai"), do: "w-1 flex-shrink-0 bg-info"
  def provider_tab_class("anthropic"), do: "w-1 flex-shrink-0 bg-primary"
  def provider_tab_class("ollama"), do: "w-1 flex-shrink-0 bg-secondary"
  def provider_tab_class(_), do: "w-1 flex-shrink-0 bg-info"

  def provider_tab_style(_provider), do: nil

  @doc "Returns a DaisyUI badge class for the provider."
  def provider_badge_class(:openai), do: "badge-outline badge-info"
  def provider_badge_class(:anthropic), do: "badge-outline badge-primary"
  def provider_badge_class(:ollama), do: "badge-outline badge-secondary"
  def provider_badge_class("openai"), do: "badge-outline badge-info"
  def provider_badge_class("anthropic"), do: "badge-outline badge-primary"
  def provider_badge_class("ollama"), do: "badge-outline badge-secondary"
  def provider_badge_class(_), do: "badge-ghost"

  @doc """
  Splits a text string into `{:text, content}` and `{:placeholder, NAME_1}` segments.

  Placeholders are `<NAME_1>` style tokens in the sanitized content.
  """
  def split_with_placeholders(text) when is_binary(text) do
    ~r/<([A-Z]+_\d+)>/
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.map(fn
      {segment, idx} when rem(idx, 2) == 0 -> {:text, segment}
      {segment, _idx} -> {:placeholder, segment}
    end)
    |> Enum.reject(fn
      {:text, ""} -> true
      _ -> false
    end)
  end

  def split_with_placeholders(_), do: []

  defp split_with_flagged(text, []), do: [{:text, text}]

  defp split_with_flagged(text, [_ | _] = flagged) do
    pattern = Enum.map_join(flagged, "|", &Regex.escape/1)

    ~r/#{pattern}/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn
      segment ->
        if segment in flagged, do: {:flagged, segment}, else: {:text, segment}
    end)
  end

  @doc """
  Renders a clickable statistics card with icon, value, and active state.

  Used in the conversations queue for stat-based filtering (e.g. PII detected,
  opt-outs handled). Clicking fires `on_click` with a `filter` value.
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :subtext, :string, default: nil
  attr :value_class, :string, default: nil
  attr :on_click, :string, default: "stat-card-click"
  attr :filter, :string, default: nil
  attr :phx_target, :any, default: nil

  def stat_card_clickable(assigns) do
    ~H"""
    <div
      class={[
        "card card-border bg-base-200 cursor-pointer transition-all hover:bg-base-300",
        @active && "border-primary ring-1 ring-primary/20"
      ]}
      phx-click={@on_click}
      phx-value-filter={@filter}
      phx-target={@phx_target}
    >
      <div class="card-body p-4 gap-1">
        <div class="flex items-center justify-between mb-2">
          <.icon name={@icon} class="w-5 h-5 text-base-content/50" />
        </div>
        <span class={["text-[30px] font-semibold leading-none", @value_class || "text-base-content"]}>
          {@value}
        </span>
        <span class="text-xs font-medium text-base-content/60 mt-0.5">{@title}</span>
        <span :if={@subtext} class="text-[11px] text-base-content/50 mt-2">
          {@subtext}
        </span>
      </div>
    </div>
    """
  end

  @doc "Renders a small badge indicating a conversation was opted out."
  def opted_out_badge(assigns) do
    ~H"""
    <span class="badge badge-sm badge-ghost gap-1 text-base-content/50">
      <.icon name="hero-no-symbol" class="w-3 h-3" /> Opted out
    </span>
    """
  end

  @doc """
  Renders a normal conversation card with a 2-line message preview.

  The preview may contain `<NAME_1>` style placeholders which are rendered
  as `.placeholder-badge` inline pills.
  """
  attr :id, :string, required: true
  attr :preview, :string, required: true
  attr :source_provider, :atom, required: true
  attr :total_pii, :integer, required: true
  attr :turn_count, :integer, required: true
  attr :last_active_at_us, :integer, required: true
  attr :on_card_click, :string, default: "card-click"

  def conversation_card(assigns) do
    ~H"""
    <div
      class="card card-border bg-base-200 cursor-pointer transition-all hover:bg-base-300 hover:-translate-y-px overflow-hidden flex"
      phx-click={@on_card_click}
      phx-value-id={@id}
    >
      <div class={provider_tab_class(@source_provider)}></div>
      <div class="card-body p-4 min-w-0">
        <p class="text-sm leading-relaxed line-clamp-2 mb-2.5 text-base-content">
          <%= for {type, content} <- split_with_placeholders(@preview) do %>
            <%= if type == :placeholder do %>
              <span class="badge badge-outline badge-sm font-mono text-xs cursor-pointer text-primary hover:bg-primary/10">{content}</span>
            <% else %>
              {content}
            <% end %>
          <% end %>
        </p>
        <div class="flex gap-1.5 flex-wrap items-center text-[11px] text-base-content/60">
          <span class={["badge badge-sm", provider_badge_class(@source_provider)]}>
            {humanize_provider(@source_provider)}
          </span>
          <span :if={@total_pii > 0} class="font-mono text-primary">
            {@total_pii} PII
          </span>
          <span :if={@total_pii == 0} class="font-mono">0 PII</span>
          <span>·</span>
          <span>{@turn_count} turns</span>
          <span>·</span>
          <span>{format_relative_time(@last_active_at_us)}</span>
          <span>·</span>
          <div class="tooltip tooltip-bottom" data-tip={@id}>
            <span class="font-mono">{String.slice(@id, 0..7)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a tombstoned conversation card (opted out, mapping cleared).

  Shows stats-only information: request count, PII types, and an opted-out badge.
  No message preview is shown because the mapping data has been deleted.
  """
  attr :id, :string, required: true
  attr :source_provider, :atom, required: true
  attr :request_count, :integer, required: true
  attr :pii_type_count, :integer, required: true
  attr :pii_types, :list, required: true
  attr :total_pii, :integer, required: true
  attr :last_active_at_us, :integer, required: true
  attr :on_card_click, :string, default: "card-click"

  def conversation_card_tombstoned(assigns) do
    ~H"""
    <div
      class="card card-border bg-base-200 cursor-pointer transition-all hover:bg-base-300 hover:-translate-y-px overflow-hidden flex"
      phx-click={@on_card_click}
      phx-value-id={@id}
    >
      <div class={provider_tab_class(@source_provider)}></div>
      <div class="card-body p-4 min-w-0">
        <div class="flex items-center gap-2 mb-2.5 flex-wrap text-[13px] text-base-content">
          <span class={["badge badge-sm", provider_badge_class(@source_provider)]}>
            {humanize_provider(@source_provider)}
          </span>
          <span>{@request_count} requests</span>
          <span class="text-[11px] text-base-content/60">·</span>
          <span>{@pii_type_count} PII types detected</span>
          <span class="text-[11px] text-base-content/60">·</span>
          <span class="text-xs text-base-content/60">
            last activity {format_relative_time(@last_active_at_us)}
          </span>
        </div>
        <div :if={@pii_types != []} class="flex gap-1.5 flex-wrap items-center mb-2.5">
          <span
            :for={type <- @pii_types}
            class="badge badge-xs badge-soft badge-primary font-mono uppercase"
          >{format_pii_type(type)}</span>
        </div>
        <div class="flex gap-1.5 flex-wrap items-center text-[11px] text-base-content/60">
          <span class="font-mono text-primary">{@total_pii} PII</span>
          <span>·</span>
          <span>{format_relative_time(@last_active_at_us)}</span>
          <span>·</span>
          <div class="tooltip tooltip-bottom" data-tip={@id}>
            <span class="font-mono">{String.slice(@id, 0..7)}</span>
          </div>
          <span class="flex-1"></span>
          <.opted_out_badge />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a conversation card for audit-off mode (stats only, no PII content).

  Similar to tombstoned but without the opted-out badge, since the conversation
  was never opted out — audit mode was simply off.
  """
  attr :id, :string, required: true
  attr :source_provider, :atom, required: true
  attr :request_count, :integer, required: true
  attr :pii_types, :list, required: true
  attr :total_pii, :integer, required: true
  attr :last_active_at_us, :integer, required: true
  attr :on_card_click, :string, default: "card-click"

  def conversation_card_audit_off(assigns) do
    ~H"""
    <div
      class="card card-border bg-base-200 cursor-pointer transition-all hover:bg-base-300 hover:-translate-y-px overflow-hidden flex"
      phx-click={@on_card_click}
      phx-value-id={@id}
    >
      <div class={provider_tab_class(@source_provider)}></div>
      <div class="card-body p-4 min-w-0">
        <div class="flex items-center gap-2 mb-2.5 flex-wrap text-[13px] text-base-content">
          <span class={["badge badge-sm", provider_badge_class(@source_provider)]}>
            {humanize_provider(@source_provider)}
          </span>
          <span>{@request_count} requests</span>
          <span class="text-[11px] text-base-content/60">·</span>
          <span>{@total_pii} PII</span>
          <span class="text-[11px] text-base-content/60">·</span>
          <span class="text-xs text-base-content/60">
            last activity {format_relative_time(@last_active_at_us)}
          </span>
        </div>
        <div :if={@pii_types != []} class="flex gap-1.5 flex-wrap items-center mb-2.5">
          <span
            :for={type <- @pii_types}
            class="badge badge-xs badge-soft badge-primary font-mono uppercase"
          >{format_pii_type(type)}</span>
        </div>
        <div class="flex gap-1.5 flex-wrap items-center text-[11px] text-base-content/60">
          <span class="font-mono text-primary">{@total_pii} PII</span>
          <span>·</span>
          <span>{format_relative_time(@last_active_at_us)}</span>
          <span>·</span>
          <div class="tooltip tooltip-bottom" data-tip={@id}>
            <span class="font-mono">{String.slice(@id, 0..7)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Slideover Components ─────────────────────────────────────────────

  @doc """
  Renders the slideover overlay + panel. Pass `nil` for `slideover` to render nothing.
  """
  attr :slideover, :map, default: nil
  attr :phx_target, :any, default: nil

  def slideover(assigns) do
    ~H"""
    <div
      :if={@slideover}
      id="slideover"
      class="fixed inset-0 bg-base-content/40 backdrop-blur-sm z-[200] animate-[fadeIn_0.15s_ease-out]"
      phx-click="close-slideover"
      phx-target={@phx_target}
      phx-window-keydown="close-slideover"
      phx-key="Escape"
    >
      <div
        phx-window-keydown="navigate-message"
        phx-key="j"
        phx-value-direction="next"
        phx-target={@phx_target}
        style="display: none;"
      >
      </div>
      <div
        phx-window-keydown="navigate-message"
        phx-key="k"
        phx-value-direction="prev"
        phx-target={@phx_target}
        style="display: none;"
      >
      </div>
      <div
        phx-window-keydown="navigate-message"
        phx-key="ArrowDown"
        phx-value-direction="next"
        phx-target={@phx_target}
        style="display: none;"
      >
      </div>
      <div
        phx-window-keydown="navigate-message"
        phx-key="ArrowUp"
        phx-value-direction="prev"
        phx-target={@phx_target}
        style="display: none;"
      >
      </div>
      <script :type={ColocatedHook} name=".PiiTagFilter">
        export default {
          mounted() {
            this.activeFilter = null;
            this.boundClick = (e) => this.handleClick(e);
            this.boundKey = (e) => this.handleKey(e);
            this.el.addEventListener("click", this.boundClick);
            document.addEventListener("keydown", this.boundKey);
          },
          destroyed() {
            this.el.removeEventListener("click", this.boundClick);
            document.removeEventListener("keydown", this.boundKey);
          },
          updated() {
            this.clearHighlights();
            this.activeFilter = null;
          },
          handleClick(e) {
            const tag = e.target.closest(".pii-tag");
            if (!tag) return;
            const type = tag.dataset.piiFilter;
            if (!type) return;
            e.stopPropagation();

            if (this.activeFilter === type) {
              this.clearHighlights();
              return;
            }

            this.clearHighlights();
            this.activeFilter = type;
            tag.classList.add("bg-primary/30", "border-primary", "shadow-[0_0_0_2px_oklch(70%_0.12_70_/_0.25)]");

            this.el.querySelectorAll(".placeholder-badge").forEach(chip => {
              if (chip.dataset.piiType === type) {
                chip.classList.add("bg-primary/30", "border-primary", "shadow-[0_0_0_2px_oklch(70%_0.12_70_/_0.20)]");
              }
            });
          },
          handleKey(e) {
            if (e.key === "Escape" && this.activeFilter) {
              this.clearHighlights();
            }
          },
          clearHighlights() {
            this.activeFilter = null;
            const tailwindActive = ["bg-primary/30", "border-primary", "shadow-[0_0_0_2px_oklch(70%_0.12_70_/_0.25)]"];
            const tailwindHighlight = ["bg-primary/30", "border-primary", "shadow-[0_0_0_2px_oklch(70%_0.12_70_/_0.20)]"];
            this.el.querySelectorAll(".pii-tag").forEach(t => t.classList.remove(...tailwindActive));
            this.el.querySelectorAll(".placeholder-badge").forEach(c => c.classList.remove(...tailwindHighlight));
          }
        };
      </script>
      <div
        id="drawer-panel"
        class="fixed top-0 right-0 bottom-0 w-[580px] max-w-full bg-base-200 z-[201] shadow-[-8px_0_32px_rgba(0,0,0,0.4)] flex flex-col transform transition-transform duration-200 ease-out scroll-thin"
        onclick="event.stopPropagation()"
        phx-hook=".PiiTagFilter"
      >
        <button
          class="btn btn-sm btn-circle btn-ghost absolute top-4 right-4"
          phx-click="close-slideover"
          phx-target={@phx_target}
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
        <.slideover_header slideover={@slideover} phx_target={@phx_target} />
        <.slideover_body slideover={@slideover} phx_target={@phx_target} />
        <.slideover_footer slideover={@slideover} />
      </div>
    </div>
    """
  end

  @doc """
  Renders the placeholder popover. The popover is always in the DOM but only
  visible when `active_placeholder` is non-nil. Anchored to the chip with
  matching `data-placeholder` value via the `.PlaceholderPopover` JS hook.
  """
  attr :active_placeholder, :any, default: nil
  attr :phx_target, :any, default: nil

  def placeholder_popover(assigns) do
    ~H"""
    <div
      id="placeholder-popover"
      class="fixed z-[300] card card-border bg-base-200 shadow-2xl min-w-[220px] max-w-[360px] hidden text-sm overflow-visible"
      data-active={
        case @active_placeholder do
          %{"placeholder" => p} -> p
          _ -> ""
        end
      }
      data-anchor={
        case @active_placeholder do
          %{"placeholder" => p} -> p
          _ -> ""
        end
      }
      phx-click-away="close-placeholder-popover"
      phx-target={@phx_target}
      phx-hook=".PlaceholderPopover"
    >
      <span class="absolute -top-1.5 left-5 w-3 h-3 bg-base-200 border-l border-t border-base-300 rotate-45"></span>
      <button
        type="button"
        class="absolute top-1 right-1 w-5 h-5 rounded btn btn-xs btn-ghost"
        phx-click="close-placeholder-popover"
        phx-target={@phx_target}
        aria-label="Close"
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
      <%= if @active_placeholder do %>
        <div class="flex items-center gap-2 p-2.5 px-3 min-h-[36px]">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-primary flex-shrink-0">{String.capitalize(
            @active_placeholder["pii_type"]
          )}</span>
          <span class="font-mono truncate flex-1 min-w-0 text-xs">{@active_placeholder["original"]}</span>
          <div class="flex gap-1 flex-shrink-0 ml-1">
            <button
              type="button"
              class="w-6 h-6 rounded btn btn-xs btn-outline btn-success"
              data-flag-judgement="true"
              data-placeholder={@active_placeholder["placeholder"]}
              data-original={@active_placeholder["original"]}
              data-pii-type={@active_placeholder["pii_type"]}
              title="True positive"
              aria-label="True positive"
            >
              <.icon name="hero-check" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              class="w-6 h-6 rounded btn btn-xs btn-outline btn-error"
              data-flag-judgement="false"
              data-placeholder={@active_placeholder["placeholder"]}
              data-original={@active_placeholder["original"]}
              data-pii-type={@active_placeholder["pii_type"]}
              title="False positive"
              aria-label="False positive"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>
      <% end %>
    </div>
    <script :type={ColocatedHook} name=".PlaceholderPopover">
      export default {
        mounted() {
          this.observer = new MutationObserver(() => this.syncToAnchor());
          this.observer.observe(this.el, {
            attributes: true,
            attributeFilter: ["data-active", "data-anchor"]
          });
          this.boundDocClick = (e) => this.handleDocClick(e);
          this.boundKey = (e) => this.handleKey(e);
          document.addEventListener("click", this.boundDocClick, true);
          document.addEventListener("keydown", this.boundKey);
          this.syncToAnchor();
        },
        destroyed() {
          this.observer && this.observer.disconnect();
          document.removeEventListener("click", this.boundDocClick, true);
          document.removeEventListener("keydown", this.boundKey);
        },
        updated() {
          this.syncToAnchor();
        },
        syncToAnchor() {
          const active = this.el.dataset.active || "";
          if (!active) {
            this.el.classList.add("hidden");
            this.el.style.left = "";
            this.el.style.top = "";
            return;
          }
          const anchor = this.el.dataset.anchor || active;
          const chip = document.querySelector('[data-placeholder="' + cssEscape(anchor) + '"]');
          if (!chip) {
            this.el.classList.remove("hidden");
            return;
          }
          const rect = chip.getBoundingClientRect();
          const popRect = this.el.getBoundingClientRect();
          const margin = 8;
          let left = rect.left;
          let top = rect.bottom + 8;
          if (left + popRect.width + margin > window.innerWidth) {
            left = Math.max(margin, window.innerWidth - popRect.width - margin);
          }
          if (top + popRect.height + margin > window.innerHeight) {
            top = Math.max(margin, rect.top - popRect.height - 8);
          }
          this.el.style.left = left + "px";
          this.el.style.top = top + "px";
          const arrow = this.el.querySelector("span:first-child");
          if (arrow) {
            const desired = rect.left + 16;
            const clamped = Math.max(12, Math.min(desired - left, popRect.width - 12));
            arrow.style.left = clamped + "px";
          }
          this.el.classList.remove("hidden");
        },
        handleDocClick(e) {
          if (this.el.classList.contains("hidden")) return;
          if (this.el.contains(e.target)) return;
          this.pushEvent("close-placeholder-popover", {});
        },
        handleKey(e) {
          if (this.el.classList.contains("hidden")) return;
          if (e.key === "Escape") {
            this.pushEvent("close-placeholder-popover", {});
          }
        }
      };
      function cssEscape(s) {
        if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
        return s.replace(/(["\\\\\[\]:.>+\-*#])/g, "\\\\$1");
      }
    </script>
    """
  end

  @doc """
  Floating "Flag as false negative" button. Shown by the colocated
  `.SelectionDetector` hook when the user selects text inside a chat
  message. Hidden otherwise.
  """
  attr :phx_target, :any, default: nil

  def selection_fab(assigns) do
    ~H"""
    <div
      id="selection-fab"
      class="fixed z-[300] hidden items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-error bg-base-200 border border-base-300 rounded-md shadow-lg cursor-pointer whitespace-nowrap transition-all hover:border-error"
      phx-target={@phx_target}
      phx-hook=".SelectionDetector"
    >
      <.icon name="hero-flag" class="w-3.5 h-3.5" />
      <span>Flag as false negative</span>
    </div>
    <script :type={ColocatedHook} name=".SelectionDetector">
      export default {
        mounted() {
          this.delayTimer = null;
          this.boundMouseUp = () => this.handleMouseUp();
          this.boundMouseDown = () => this.hideFab();
          this.boundScroll = () => this.hideFab();
          this.boundClick = () => this.handleClick();
          const doc = this.el.ownerDocument;
          doc.addEventListener("mouseup", this.boundMouseUp);
          doc.addEventListener("mousedown", this.boundMouseDown);
          doc.addEventListener("scroll", this.boundScroll, true);
          this.el.addEventListener("click", this.boundClick);
        },
        destroyed() {
          if (this.delayTimer) clearTimeout(this.delayTimer);
          const doc = this.el.ownerDocument;
          doc.removeEventListener("mouseup", this.boundMouseUp);
          doc.removeEventListener("mousedown", this.boundMouseDown);
          doc.removeEventListener("scroll", this.boundScroll, true);
          this.el.removeEventListener("click", this.boundClick);
        },
        handleMouseUp() {
          if (this.delayTimer) clearTimeout(this.delayTimer);
          this.delayTimer = setTimeout(() => this.checkSelection(), 200);
        },
        checkSelection() {
          const sel = window.getSelection();
          if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
            this.hideFab();
            return;
          }
          const text = sel.toString().trim();
          if (!text) {
            this.hideFab();
            return;
          }
          const range = sel.getRangeAt(0);
          const node = range.commonAncestorContainer;
          const el = node.nodeType === 1 ? node : node.parentElement;
          if (el && el.closest && el.closest(".placeholder-badge")) {
            this.hideFab();
            return;
          }
          const rect = range.getBoundingClientRect();
          this.showFab(rect, text);
        },
        showFab(rect, text) {
          this.el.classList.remove("hidden");
          this.el.classList.add("inline-flex");
          this.el.style.left = Math.max(8, rect.left) + "px";
          this.el.style.top = (rect.top - 36) + "px";
          this.el.dataset.text = text;
        },
        hideFab() {
          this.el.classList.add("hidden");
          this.el.classList.remove("inline-flex");
          this.el.dataset.text = "";
        },
        handleClick() {
          const text = this.el.dataset.text;
          if (!text) return;
          const sel = window.getSelection();
          let x = 0;
          let y = 0;
          if (sel && sel.rangeCount > 0) {
            const r = sel.getRangeAt(0).getBoundingClientRect();
            x = Math.round(r.left);
            y = Math.round(r.bottom + 8);
          }
          this.pushEvent("open-selection-popover", { text: text, x: x, y: y });
        }
      };
    </script>
    """
  end

  @doc """
  Popover shown when the user clicks the selection FAB. Displays the
  selected text in a quoted block with Confirm miss / Not PII buttons.
  """
  attr :active_selection, :any, default: nil
  attr :phx_target, :any, default: nil

  def selection_popover(assigns) do
    ~H"""
    <div
      id="selection-popover"
      class="fixed z-[300] hidden min-w-[220px] max-w-[360px] card card-border bg-base-200 shadow-2xl overflow-hidden"
      data-active={
        case @active_selection do
          %{"text" => t} -> t
          _ -> ""
        end
      }
      phx-click-away="dismiss-selection-popover"
      phx-target={@phx_target}
      phx-hook=".SelectionPopover"
    >
      <span class="absolute -top-1.5 left-5 w-3 h-3 bg-base-200 border-l border-t border-base-300 rotate-45"></span>
      <button
        type="button"
        class="absolute top-1 right-1 w-5 h-5 flex items-center justify-center btn btn-xs btn-ghost"
        phx-click="dismiss-selection-popover"
        phx-target={@phx_target}
        aria-label="Close"
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
      <%= if @active_selection do %>
        <div class="flex items-center gap-2.5 p-2.5 px-3">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-error flex-shrink-0">FN</span>
          <span class="flex-1 min-w-0 italic text-xs font-mono truncate">{@active_selection["text"]}</span>
          <div class="flex gap-1 flex-shrink-0 ml-1">
            <button
              type="button"
              class="w-6 h-6 rounded btn btn-xs btn-outline btn-error"
              phx-click="confirm-false-negative"
              phx-target={@phx_target}
              phx-value-text={@active_selection["text"]}
              title="Confirm miss"
              aria-label="Confirm miss"
            >
              <.icon name="hero-check" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              class="w-6 h-6 rounded btn btn-xs btn-ghost"
              phx-click="dismiss-selection-popover"
              phx-target={@phx_target}
              title="Not PII"
              aria-label="Not PII"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>
      <% end %>
    </div>
    <script :type={ColocatedHook} name=".SelectionPopover">
      export default {
        mounted() {
          this.observer = new MutationObserver(() => this.syncToSelection());
          this.observer.observe(this.el, {
            attributes: true,
            attributeFilter: ["data-active"]
          });
          this.boundDocClick = (e) => this.handleDocClick(e);
          this.boundKey = (e) => this.handleKey(e);
          document.addEventListener("click", this.boundDocClick, true);
          document.addEventListener("keydown", this.boundKey);
          this.syncToSelection();
        },
        destroyed() {
          this.observer && this.observer.disconnect();
          document.removeEventListener("click", this.boundDocClick, true);
          document.removeEventListener("keydown", this.boundKey);
        },
        updated() {
          this.syncToSelection();
        },
        syncToSelection() {
          const active = this.el.dataset.active || "";
          if (!active) {
            this.el.classList.add("hidden");
            this.el.style.left = "";
            this.el.style.top = "";
            return;
          }
          const sel = window.getSelection();
          if (sel && sel.rangeCount > 0) {
            const rect = sel.getRangeAt(0).getBoundingClientRect();
            const popRect = this.el.getBoundingClientRect();
            const margin = 8;
            let left = rect.left;
            let top = rect.bottom + 8;
            if (left + popRect.width + margin > window.innerWidth) {
              left = Math.max(margin, window.innerWidth - popRect.width - margin);
            }
            if (top + popRect.height + margin > window.innerHeight) {
              top = Math.max(margin, rect.top - popRect.height - 8);
            }
            this.el.style.left = left + "px";
            this.el.style.top = top + "px";
            const arrow = this.el.querySelector("span:first-child");
            if (arrow) {
              const desired = rect.left + 16;
              const clamped = Math.max(12, Math.min(desired - left, popRect.width - 12));
              arrow.style.left = clamped + "px";
            }
          }
          this.el.classList.remove("hidden");
        },
        handleDocClick(e) {
          if (this.el.classList.contains("hidden")) return;
          if (this.el.contains(e.target)) return;
          if (e.target.closest && e.target.closest("#selection-fab")) return;
          this.pushEvent("dismiss-selection-popover", {});
        },
        handleKey(e) {
          if (this.el.classList.contains("hidden")) return;
          if (e.key === "Escape") {
            this.pushEvent("dismiss-selection-popover", {});
          }
        }
      };
    </script>
    """
  end

  @doc """
  Vertical message navigation rail. One dot per message, styled by role.
  The dot at `active_index` gets the active class. Clicking a dot pushes
  the navigate-message event (or the colocated ScrollSpy hook handles
  smooth scroll + highlight pulse client-side).
  """
  attr :messages, :list, required: true
  attr :active_index, :integer, default: 0
  attr :phx_target, :any, default: nil

  def message_nav_rail(assigns) do
    ~H"""
    <div
      id="msg-nav-rail"
      class="w-8 flex flex-col items-center gap-1.5 py-2 px-1 flex-shrink-0 border-l border-base-300 overflow-y-auto bg-base-200 scroll-thin"
      data-active-index={@active_index}
      phx-target={@phx_target}
      phx-hook=".ScrollSpy"
    >
      <%= for {msg, idx} <- Enum.with_index(@messages) do %>
        <div
          class={[
            "w-2 h-2 rounded-full border-2 bg-transparent cursor-pointer transition-all flex-shrink-0 flex items-center justify-center p-0 hover:scale-[1.3]",
            nav_dot_class(msg.role),
            idx == @active_index && "scale-[1.4] opacity-100!"
          ]}
          data-msg-index={idx}
          data-msg-role={msg.role}
          data-active={to_string(idx == @active_index)}
          phx-click="navigate-message"
          phx-target={@phx_target}
          phx-value-index={idx}
          title={nav_dot_title(msg.role)}
        >
          <%= case msg.role do %>
            <% "tool_call" -> %>
              <.icon name="hero-wrench-screwdriver" class="w-3 h-3" />
            <% "tool_result" -> %>
              <.icon name="hero-arrow-right-circle" class="w-3 h-3" />
            <% _ -> %>
          <% end %>
        </div>
      <% end %>
    </div>
    <script :type={ColocatedHook} name=".ScrollSpy">
      export default {
        mounted() {
          this.observer = null;
          this.boundScroll = () => this.handleScroll();
          this.chatContainer = document.querySelector("#drawer-panel .scroll-thin");
          if (this.chatContainer) {
            this.chatContainer.addEventListener("scroll", this.boundScroll, { passive: true });
          }
          window.addEventListener("resize", this.boundScroll);
          this.setupObserver();
        },
        destroyed() {
          if (this.chatContainer) {
            this.chatContainer.removeEventListener("scroll", this.boundScroll);
          }
          window.removeEventListener("resize", this.boundScroll);
          if (this.observer) this.observer.disconnect();
        },
        updated() {
          this.setupObserver();
          const active = parseInt(this.el.dataset.activeIndex || "0", 10);
          if (this.lastActive !== active) {
            this.lastActive = active;
            this.scrollToMessage(active);
          }
        },
        setupObserver() {
          if (!this.chatContainer) return;
          if (this.observer) this.observer.disconnect();
          const messages = this.chatContainer.querySelectorAll("[data-msg-index]");
          this.observer = new IntersectionObserver(
            (entries) => {
              let best = null;
              let bestRatio = 0;
              for (const entry of entries) {
                if (entry.intersectionRatio > bestRatio) {
                  bestRatio = entry.intersectionRatio;
                  best = entry.target;
                }
              }
              if (best && bestRatio > 0.1) {
                const idx = parseInt(best.dataset.msgIndex, 10);
                this.el.dataset.activeIndex = idx;
              }
            },
            { root: this.chatContainer, threshold: [0, 0.25, 0.5, 0.75, 1] }
          );
          messages.forEach((m) => this.observer.observe(m));
        },
        handleScroll() {
        },
        scrollToMessage(index) {
          if (!this.chatContainer) return;
          const target = this.chatContainer.querySelector(
            '[data-msg-index="' + index + '"]'
          );
          if (!target) return;
          target.scrollIntoView({ behavior: "smooth", block: "start" });
          target.classList.add("msg-highlight-pulse");
          setTimeout(() => target.classList.remove("msg-highlight-pulse"), 1500);
        }
      };
    </script>
    """
  end

  defp nav_dot_class("user"), do: "border-primary"
  defp nav_dot_class("assistant"), do: "border-accent bg-accent/40"
  defp nav_dot_class("tool_call"), do: "border-warning bg-warning/60"
  defp nav_dot_class("tool_result"), do: "border-base-content/50"
  defp nav_dot_class(_), do: ""

  defp nav_dot_title("user"), do: "User message"
  defp nav_dot_title("assistant"), do: "Assistant message"
  defp nav_dot_title("tool_call"), do: "Tool call"
  defp nav_dot_title("tool_result"), do: "Tool result"
  defp nav_dot_title(_), do: "Message"

  defp slideover_header(assigns) do
    ~H"""
    <div class="p-6 pb-4 border-b border-base-300 pr-[60px]">
      <h2 class="text-lg font-semibold mb-4">Conversation Review</h2>
      <div class="flex flex-wrap gap-6 items-baseline">
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">Source Provider</span>
          <span class="text-sm font-medium">{humanize_provider(@slideover.source_provider)}</span>
        </div>
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">Target Provider</span>
          <span class="text-sm font-medium">
            {if @slideover.target_provider,
              do: humanize_provider(@slideover.target_provider),
              else: "—"}
          </span>
        </div>
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">Conversation</span>
          <span class="text-sm font-medium font-mono">{String.slice(@slideover.id, 0..7)}</span>
        </div>
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">Last activity</span>
          <span class="text-sm font-medium">{format_relative_time(@slideover.last_active_at_us)}</span>
        </div>
        <div :if={@slideover.view == :chat} class="flex flex-col gap-0.5 min-w-0">
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">Turns</span>
          <span class="text-sm font-medium">{@slideover.turn_count}</span>
        </div>
      </div>
      <div :if={map_size(@slideover.pii_types) > 0} class="flex flex-wrap gap-1.5 mt-3">
        <.pii_tag
          :for={{type, count} <- @slideover.pii_types}
          type={type}
          count={count}
        />
      </div>
    </div>
    """
  end

  defp slideover_body(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto flex flex-col">
      <%= case @slideover.view do %>
        <% :chat -> %>
          <div class="flex flex-1 min-h-0 w-full">
            <div class="flex-1 overflow-y-auto min-h-0 scroll-thin">
              <.chat_message
                :for={msg <- @slideover.messages}
                message={msg}
                index={Enum.find_index(@slideover.messages, &(&1.id == msg.id))}
                mapping={@slideover.mapping}
                active_placeholder={
                  @slideover[:active_placeholder] && @slideover.active_placeholder["placeholder"]
                }
                flagged_false_negatives={@slideover[:flagged_false_negatives] || []}
                active={
                  Enum.find_index(@slideover.messages, &(&1.id == msg.id)) ==
                    (@slideover[:active_message_index] || 0)
                }
                phx_target={@phx_target}
              />
              <div
                :if={@slideover.messages == []}
                class="flex flex-col items-center justify-center py-16 px-8 text-center text-base-content/60"
              >
                <p>No messages recorded for this conversation</p>
              </div>
            </div>
            <.message_nav_rail
              messages={@slideover.messages}
              active_index={@slideover[:active_message_index] || 0}
              phx_target={@phx_target}
            />
          </div>
          <.placeholder_popover
            active_placeholder={@slideover[:active_placeholder]}
            phx_target={@phx_target}
          />
          <.selection_fab phx_target={@phx_target} />
          <.selection_popover
            active_selection={@slideover[:active_selection]}
            phx_target={@phx_target}
          />
        <% :stats -> %>
          <div class="p-5 flex flex-col gap-6">
            <div class="grid grid-cols-3 gap-4">
              <div class="flex flex-col gap-1 p-3 bg-base-300/50 border border-base-300 rounded-md">
                <span class="text-xl font-semibold">{length(@slideover.events)}</span>
                <span class="text-[11px] text-base-content/60">Total requests</span>
              </div>
              <div class="flex flex-col gap-1 p-3 bg-base-300/50 border border-base-300 rounded-md">
                <span class="text-xl font-semibold">
                  {Enum.sum(Enum.map(@slideover.events, & &1.pii_detected_count))}
                </span>
                <span class="text-[11px] text-base-content/60">PII detected</span>
              </div>
              <div class="flex flex-col gap-1 p-3 bg-base-300/50 border border-base-300 rounded-md">
                <span class="text-xl font-semibold">
                  {avg_latency_ms(@slideover.events)}
                </span>
                <span class="text-[11px] text-base-content/60">Avg latency</span>
              </div>
            </div>
            <div :if={map_size(@slideover.pii_types) > 0} class="flex flex-col gap-2">
              <span class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">PII Type Breakdown</span>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={{type, count} <- @slideover.pii_types}
                  class="badge badge-xs badge-soft badge-primary font-mono uppercase"
                >
                  {format_pii_type(type)} ×{count}
                </span>
              </div>
            </div>
            <div class="flex flex-col gap-2">
              <span class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">Request Log</span>
              <div class="flex flex-col border border-base-300 rounded-md overflow-hidden">
                <.request_log_row
                  :for={event <- @slideover.events}
                  event={event}
                  expanded={@slideover.expanded_event_id == event.id}
                  phx_target={@phx_target}
                />
              </div>
              <div
                :if={@slideover.events == []}
                class="flex flex-col items-center justify-center py-16 px-8 text-center text-base-content/60"
              >
                <p>No requests recorded</p>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp slideover_footer(assigns) do
    ~H"""
    <div class="px-7 py-2.5 border-t border-base-300 text-xs text-base-content/60 flex items-center gap-1">
      <%= case @slideover.badge do %>
        <% :audit_off -> %>
          <span>Audit Mode OFF — no message content available</span>
        <% :opted_out -> %>
          <span>Conversation opted out — no data retained</span>
        <% nil -> %>
          <span>
            Press <kbd class="kbd kbd-sm">J</kbd>
            / <kbd class="kbd kbd-sm">K</kbd>
            to navigate messages
          </span>
      <% end %>
    </div>
    """
  end

  @doc "Renders a single PII type tag with count (e.g. NAME ×2)."
  attr :type, :atom, required: true
  attr :count, :integer, required: true

  def pii_tag(assigns) do
    ~H"""
    <span
      class="badge badge-soft badge-primary badge-sm font-mono cursor-pointer pii-tag"
      data-pii-filter={String.upcase(Atom.to_string(@type))}
    >
      {format_pii_type(@type)}
      <span class="opacity-70 ml-0.5">×{@count}</span>
    </span>
    """
  end

  @doc """
  Renders a single chat message bubble. For user/assistant roles, splits the
  content on placeholders (e.g. <NAME_1>) and renders them as inline chips.
  For tool_call/tool_result roles, renders the JSON in a tool card.
  """
  attr :message, :map, required: true
  attr :index, :integer, default: 0
  attr :mapping, :map, default: %{}
  attr :active_placeholder, :any, default: nil
  attr :flagged_false_negatives, :list, default: []
  attr :active, :boolean, default: false
  attr :phx_target, :any, default: nil

  def chat_message(assigns) do
    ~H"""
    <div
      class={["py-5 px-7 border-b border-base-300 last:border-b-0", @active && "msg-highlight"]}
      data-msg-index={@index}
      data-role={@message.role}
    >
      <div class="flex items-center gap-2 mb-2">
        <span class={[
          "text-[11px] font-semibold uppercase tracking-wide",
          chat_role_text_class(@message.role)
        ]}>
          {chat_role_label(@message.role)}
        </span>
        <time class="text-[11px] text-base-content/50 font-mono">{format_time_of_day(
          @message.created_at
        )}</time>
      </div>
      <%= cond do %>
        <% @message.role in ["user", "assistant"] -> %>
          <div class="text-[15px] leading-relaxed text-base-content">
            <%= for {type, content} <- split_with_placeholders(@message.sanitized_content || "") do %>
              <%= if type == :placeholder do %>
                <span
                  class={[
                    "badge badge-outline badge-sm font-mono text-xs cursor-pointer text-primary hover:bg-primary/10 placeholder-badge",
                    @active_placeholder == content && "bg-primary/20"
                  ]}
                  data-placeholder={content}
                  data-original={Map.get(@mapping, content)}
                  data-pii-type={extract_pii_type(content)}
                  data-tooltip={Map.get(@mapping, content)}
                  phx-click="open-placeholder-popover"
                  phx-target={@phx_target}
                  phx-value-placeholder={content}
                  phx-value-original={Map.get(@mapping, content)}
                  phx-value-pii-type={extract_pii_type(content)}
                >
                  {content}
                </span>
              <% else %>
                <%= for {ftype, fcontent} <- split_with_flagged(content, @flagged_false_negatives) do %>
                  <%= if ftype == :flagged do %>
                    <span class="underline decoration-error decoration-2 underline-offset-2 cursor-help">{fcontent}</span>
                  <% else %>
                    {fcontent}
                  <% end %>
                <% end %>
              <% end %>
            <% end %>
          </div>
        <% @message.role in ["tool_call", "tool_result"] -> %>
          <.tool_card role={@message.role} content={@message.sanitized_content || ""} />
        <% true -> %>
          <div class="text-[15px] leading-relaxed text-base-content">
            {@message.sanitized_content}
          </div>
      <% end %>
    </div>
    """
  end

  defp chat_role_label("user"), do: "User"
  defp chat_role_label("assistant"), do: "Assistant"
  defp chat_role_label("tool_call"), do: "Tool call"
  defp chat_role_label("tool_result"), do: "Tool result"
  defp chat_role_label(other) when is_binary(other), do: String.capitalize(other)
  defp chat_role_label(_), do: "Unknown"

  defp chat_role_text_class("user"), do: "text-primary"
  defp chat_role_text_class("assistant"), do: "text-accent"
  defp chat_role_text_class("tool_call"), do: "text-warning"
  defp chat_role_text_class("tool_result"), do: "text-base-content/50"
  defp chat_role_text_class(_), do: "text-base-content/50"

  defp extract_pii_type("NAME_1"), do: "NAME"
  defp extract_pii_type("EMAIL_1"), do: "EMAIL"
  defp extract_pii_type("<NAME_1>"), do: "NAME"
  defp extract_pii_type("<EMAIL_1>"), do: "EMAIL"

  defp extract_pii_type(content) do
    # Strip optional angle brackets
    stripped = content |> String.trim_leading("<") |> String.trim_trailing(">")

    case Regex.run(~r/^([A-Z]+)_/, stripped) do
      [_, type] -> type
      _ -> nil
    end
  end

  defp tool_card(assigns) do
    ~H"""
    <div class={[
      "rounded-md p-3 text-xs flex flex-col gap-1.5 font-mono",
      if(@role == "tool_call",
        do: "bg-warning/10 border border-warning/30",
        else: "bg-base-300/50 border border-base-300"
      )
    ]}>
      <div class={[
        "flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide",
        if(@role == "tool_call", do: "text-warning", else: "text-base-content/70")
      ]}>
        <.icon
          name={if @role == "tool_call", do: "hero-wrench-screwdriver", else: "hero-document-text"}
          class="w-3.5 h-3.5"
        />
        <span>{if @role == "tool_call", do: "Tool call", else: "Tool result"}</span>
      </div>
      <pre class="m-0 font-mono text-xs whitespace-pre-wrap break-words">
        <%= for {type, content} <- split_with_placeholders(@content) do %>
          <%= if type == :placeholder do %>
            <span class="badge badge-outline badge-sm font-mono text-xs cursor-pointer hover:badge-primary placeholder-badge">{content}</span>
          <% else %>
            {content}
          <% end %>
        <% end %>
      </pre>
    </div>
    """
  end

  defp format_time_of_day(nil), do: ""

  defp format_time_of_day(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%H:%M:%S")
  end

  defp format_time_of_day(_), do: ""

  @doc "Renders a compact request log row. Clicking expands the details."
  attr :event, :map, required: true
  attr :expanded, :boolean, default: false
  attr :phx_target, :any, default: nil

  def request_log_row(assigns) do
    ~H"""
    <div
      class={[
        "grid grid-cols-[80px_1fr_50px_60px_50px_24px] gap-3 p-2.5 items-center cursor-pointer text-sm border-b border-base-300 bg-base-200 hover:bg-base-300 transition-colors last:border-b-0",
        @expanded && "bg-base-300"
      ]}
      phx-click="expand-row"
      phx-value-event-id={@event.id}
      phx-target={@phx_target}
    >
      <span class="font-mono text-[11px] text-base-content/60">{format_time_of_day(
        @event.ended_at || @event.inserted_at
      )}</span>
      <span class="font-mono text-xs overflow-hidden text-ellipsis whitespace-nowrap">{(@event.method ||
                                                                                          "POST") <>
        " " <> (@event.request_path || "/")}</span>
      <span class={["font-mono font-semibold text-[11px]", status_text_class(@event.status)]}>{@event.status ||
        "—"}</span>
      <span class="text-[11px] font-mono text-right text-base-content/70">{format_latency(
        @event.duration_ms
      )}</span>
      <span class="text-center text-[11px]">
        <span :if={@event.pii_detected_count > 0} class="badge badge-sm badge-soft badge-primary">
          {@event.pii_detected_count}
        </span>
        <span :if={@event.pii_detected_count <= 0}>—</span>
      </span>
      <span class="flex items-center justify-center text-base-content/40">
        <.icon
          name="hero-chevron-down"
          class={["w-4 h-4 transition-transform", @expanded && "rotate-180"]}
        />
      </span>
    </div>
    <div
      :if={@expanded}
      class="p-3.5 bg-base-300/50 border-b border-base-300 animate-[expandIn_0.2s_ease-out]"
    >
      <div class="grid grid-cols-2 gap-3.5">
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
            Method + Path
          </div>
          <div class="text-sm">
            {(@event.method || "POST") <> " " <> (@event.request_path || "/")}
          </div>
        </div>
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
            Status
          </div>
          <div class={["text-sm", status_class(@event.status)]}>
            {@event.status || "—"} {status_text(@event.status)}
          </div>
        </div>
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
            Latency
          </div>
          <div class="text-sm">{format_latency(@event.duration_ms)}</div>
        </div>
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
            PII count
          </div>
          <div class="text-sm">{@event.pii_detected_count}</div>
        </div>
        <div :if={@event.pii_types != []} class="col-span-2">
          <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
            PII types
          </div>
          <div class="text-sm">
            <span
              :for={t <- decode_event_pii_types(@event.pii_types)}
              class="badge badge-xs badge-primary font-mono uppercase"
            >
              {format_pii_type(t)}
            </span>
          </div>
        </div>
      </div>
      <button
        :if={@event.conversation_id}
        class="inline-flex items-center gap-1 text-xs font-medium text-accent hover:underline mt-3.5"
        phx-click={
          JS.push("close-slideover", target: @phx_target)
          |> JS.navigate(~p"/admin/activity")
        }
      >
        View in Activity <.icon name="hero-chevron-right" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  # ── Request Volume Chart (System view) ─────────────────────────────

  @doc "Renders an inline SVG area chart for 24h request volume."
  attr :data, :list, required: true, doc: "[{bucket_start_us, count}] oldest first"
  attr :now_us, :integer, required: true

  def request_volume_chart(assigns) do
    chart = build_chart_path(assigns.data)

    assigns =
      assigns
      |> assign(:line_path, chart.line)
      |> assign(:area_path, chart.area)
      |> assign(:dot_x, chart.dot_x)
      |> assign(:dot_y, chart.dot_y)
      |> assign(:y_labels, chart.y_labels)
      |> assign(:x_labels, chart.x_labels)

    ~H"""
    <svg viewBox="0 0 800 200" class="block w-full h-auto" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="chart-gradient" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#5FA8A0" stop-opacity="0.35" />
          <stop offset="100%" stop-color="#5FA8A0" stop-opacity="0" />
        </linearGradient>
      </defs>

      <%!-- Grid lines --%>
      <%= for {y, _label} <- @y_labels do %>
        <line
          x1="60"
          y1={y}
          x2="780"
          y2={y}
          stroke="var(--color-base-300)"
          stroke-width="0.5"
          stroke-dasharray="4 4"
        />
      <% end %>

      <%!-- Y-axis labels --%>
      <%= for {y, label} <- @y_labels do %>
        <text
          x="55"
          y={y + 4}
          text-anchor="end"
          font-size="11"
          fill="oklch(from var(--color-base-content) l c h / 0.5)"
        >
          {label}
        </text>
      <% end %>

      <%!-- X-axis labels --%>
      <%= for {x, label} <- @x_labels do %>
        <text
          x={x}
          y="195"
          text-anchor="middle"
          font-size="11"
          fill="oklch(from var(--color-base-content) l c h / 0.5)"
        >
          {label}
        </text>
      <% end %>

      <%!-- Area fill --%>
      <path d={@area_path} fill="url(#chart-gradient)" />

      <%!-- Line --%>
      <path d={@line_path} fill="none" stroke="#5FA8A0" stroke-width="2" />

      <%!-- Current-value dot --%>
      <circle cx={@dot_x} cy={@dot_y} r="3" fill="#5FA8A0" />
    </svg>
    """
  end

  defp build_chart_path(data) do
    chart_w = 720
    chart_h = 160
    x_offset = 60
    y_offset = 20
    y_max = 40
    n = max(length(data), 1)

    points =
      data
      |> Enum.with_index()
      |> Enum.map(fn {{_bucket_us, count}, i} ->
        x = x_offset + i / (n - 1) * chart_w
        y = y_offset + chart_h - min(count / y_max, 1.0) * chart_h
        {Float.round(x, 2), Float.round(y, 2)}
      end)

    line_path =
      case points do
        [] ->
          ""

        [{x, y} | rest] ->
          "M #{x},#{y}" <> Enum.reduce(rest, "", fn {px, py}, acc -> acc <> " L #{px},#{py}" end)
      end

    area_path =
      case points do
        [] -> ""
        _ -> area_path(points, y_offset + chart_h)
      end

    {dot_x, dot_y} = List.last(points) || {0, 0}

    # Y-axis labels: 40, 30, 20, 10, 0
    y_labels =
      for val <- [40, 30, 20, 10, 0] do
        y = y_offset + chart_h - val / y_max * chart_h
        {Float.round(y, 2), "#{val}"}
      end

    # X-axis labels at indices 0, 6, 12, 18, 23
    x_labels = build_x_labels(data, n, x_offset, chart_w)

    %{
      line: line_path,
      area: area_path,
      dot_x: dot_x,
      dot_y: dot_y,
      y_labels: y_labels,
      x_labels: x_labels
    }
  end

  defp area_path([{x0, y0} | rest_points], bottom_y) do
    line_part =
      [{x0, y0} | rest_points]
      |> Enum.reduce("M #{x0},#{bottom_y} L #{x0},#{y0}", fn {px, py}, acc ->
        acc <> " L #{px},#{py}"
      end)

    {last_x, _} = List.last([{x0, y0} | rest_points])
    line_part <> " L #{last_x},#{bottom_y} Z"
  end

  defp build_x_labels(data, n, x_offset, chart_w) do
    indices = [0, 6, 12, 18, n - 1]
    now_us = System.system_time(:microsecond)

    for i <- indices, i < n do
      {bucket_us, _count} = Enum.at(data, i, {0, 0})
      x = x_offset + i / max(n - 1, 1) * chart_w
      label = format_chart_x_label(i, n - 1, bucket_us, now_us)
      {Float.round(x, 2), label}
    end
  end

  defp format_chart_x_label(i, last, _bucket_us, _now) when i == last, do: "Now"

  defp format_chart_x_label(_i, _last, bucket_us, _now) do
    # Convert bucket_us to hour of day
    if bucket_us > 0 do
      hour =
        bucket_us
        |> div(3_600_000_000)
        |> rem(24)
        |> abs()

      "#{String.pad_leading(Integer.to_string(hour), 2, "0")}:00"
    else
      "00:00"
    end
  end

  defp status_text(s) when is_integer(s) and s >= 200 and s < 300, do: "OK"
  defp status_text(s) when is_integer(s) and s >= 400 and s < 500, do: "Client error"
  defp status_text(s) when is_integer(s) and s >= 500, do: "Server error"
  defp status_text(_), do: ""

  defp decode_event_pii_types(nil), do: []

  defp decode_event_pii_types(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} ->
        list
        |> Enum.map(fn s ->
          try do
            String.to_existing_atom(s)
          rescue
            ArgumentError -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp decode_event_pii_types(_), do: []

  defp avg_latency_ms([]), do: "0ms"

  defp avg_latency_ms(events) do
    events
    |> Enum.map(& &1.duration_ms)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "0ms"
      ms -> format_latency(Enum.sum(ms) / length(ms))
    end
  end

  @doc "Returns a Tailwind color class for error status codes."
  def err_status_class(status) when is_integer(status) do
    cond do
      status >= 200 and status < 300 -> "text-success"
      status >= 400 and status < 500 -> "text-warning"
      status >= 500 -> "text-error"
      true -> "text-error"
    end
  end

  def err_status_class(_), do: "text-error"
end
