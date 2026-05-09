This is an LLM Privacy Proxy built with Phoenix. It intercepts API requests, strips PII, forwards to LLM providers, and restores PII in responses.

## Project-specific facts

- **No database** — No Ecto, no Postgres. Tests run with `mix test` directly (no `ecto.setup` needed).
- **Multi-provider architecture** — Configure providers via env vars: `PROVIDER_OPENAI_1_ENABLED`, `PROVIDER_ANTHROPIC_1_API_KEY`, etc. Up to 4 of each type.
- **PII pipeline** — OpenAI format is canonical. Other formats convert → sanitize → convert back via `ShhAi.PIIPipeline`.
- **Session store** — ETS (default) or Redis. Set via `SESSION_STORE_BACKEND=ets|redis` and `REDIS_URL`.
- **NER model** — Uses Bumblebee + NX/EXLA for neural entity recognition. Model: `gravitee-io/bert-small-pii-detection` (~110MB). Supports 24 PII entity types.
- **Config via `persistent_term`** — `ShhAi.Config.load()` stores all config in `:persistent_term` at startup for zero-cost reads.

## Documentation tools

- Use `hexdocs-mcp_search` for Elixir/Erlang package documentation (Phoenix, Ecto, Req, etc.)
- Use `context7` for all other documentation (Tailwind, daisyUI, JavaScript libraries, etc.)
- Use `gh_grep` to search github code using grep

## Developer commands

- `mix precommit` — Runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. Run before committing.
- `mix test test/path/to_test.exs` — Run specific test file
- `mix test --failed` — Re-run failed tests

## Test setup pattern

Tests involving PII detection need to load patterns into `:persistent_term`:

```elixir
setup do
  ShhAi.Config.load()  # Loads all config including providers
  ShhAi.PII.Patterns.load_into_persistent_term()  # Loads regex patterns
  :ok
end
```

For tests that only need patterns (no config):

```elixir
setup do
  ShhAi.PII.Patterns.load_into_persistent_term()
  :ok
end
```

## HTTP client

Use `Req` for HTTP requests. It's included and configured with Finch connection pooling. Avoid `:httpoison`, `:tesla`, `:httpc`.

## Phoenix v1.8 specifics

- **LiveView templates** must start with `<Layouts.app flash={@flash} current_scope={@current_scope}>` wrapping inner content.
- **`current_scope` errors** — Routes must be in the correct `live_session` and `current_scope` must be passed to `Layouts.app`.
- **`<.flash_group>`** — Only callable inside `layouts.ex`, not in other templates.
- **Icons** — Use `<.icon name="hero-x-mark" />` from `core_components.ex`, never `Heroicons` modules directly.
- **Form inputs** — Use `<.input field={@form[:field]} />` from `core_components.ex`. Custom classes override all defaults.

## Tailwind CSS v4

No `tailwind.config.js`. Import syntax in `app.css`:

```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/shh_ai_web";
```

daisyUI is used in this project (vendored in `assets/vendor/`). Check daisyUI docs via `context7` for component usage.

## HEEx interpolation rules

- Attributes use `{...}` syntax: `<div id={@id}>`
- Tag bodies can use `{...}` or `<%= ... %>`: `<div>{@value}</div>` or `<div><%= @value %></div>`
- Block constructs in tag bodies use `<%= ... %>`: `<%= if @show do %>...<% end %>`
- Class lists must use `[...]` syntax: `class={["base", @cond && "conditional"]}`
- No `else if` in Elixir — use `cond` or `case` for multiple conditions

## LiveView forms

Always use `to_form/2` and access via `@form[:field]`:

```elixir
# In LiveView
assign(socket, form: to_form(changeset))

# In template
<.form for={@form} id="my-form">
  <.input field={@form[:field]} />
</.form>
```

Never access changesets directly in templates.

## LiveView streams

For collections, use `stream/3` and consume via `@streams.stream_name`:

```elixir
stream(socket, :items, items, reset: true)
```

```heex
<div id="items" phx-update="stream">
  <div :for={{id, item} <- @streams.items} id={id}>
    {item.name}
  </div>
</div>
```

Streams are not enumerable — to filter/refresh, refetch and re-stream with `reset: true`.

## Elixir gotchas

- **No index access on lists** — Use `Enum.at(list, i)` or pattern matching
- **Rebinding in blocks** — Must bind result to variable: `socket = if cond do assign(socket, :x, 1) else socket end`
- **Struct access** — No `struct[:field]` syntax; use `struct.field` or `Ecto.Changeset.get_field/2`
- **No `String.to_atom/1`** on user input — Memory leak risk
