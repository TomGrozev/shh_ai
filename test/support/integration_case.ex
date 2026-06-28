defmodule ShhAi.IntegrationCase do
  @moduledoc """
  Case template for integration tests that hit real LLM providers.

  Gates tests behind per-provider env-var checks so CI can skip them
  cleanly when credentials aren't configured.

      use ShhAi.IntegrationCase, provider: :openai
      use ShhAi.IntegrationCase, provider: :anthropic
      use ShhAi.IntegrationCase, provider: :ollama

  ## Required env vars per provider

    * `:openai` — `PROVIDER_OPENAI_1_ENABLED=true` and
      `PROVIDER_OPENAI_1_API_KEY` (non-empty).
    * `:anthropic` — `PROVIDER_ANTHROPIC_1_ENABLED=true` and
      `PROVIDER_ANTHROPIC_1_API_KEY` (non-empty).
    * `:ollama` — `PROVIDER_OLLAMA_1_ENABLED=true`.

  ## Filtering

  Tests are tagged `:integration` and `:"integration_<provider>"` so they
  can be run selectively:

      mix test --only integration
      mix test --only integration:integration_openai

  You can override the provider tag with the `:tags` option, useful for
  cross-provider tests:

      use ShhAi.IntegrationCase, provider: :openai, tags: [:integration_cross_provider]
  """

  use ExUnit.CaseTemplate

  @doc """
  Macro called by `use ShhAi.IntegrationCase, provider: ...`.

  Injects:

    * the `:integration` and `:"integration_<provider>"` tags (or custom tags via `:tags`),
    * the Phoenix endpoint and verified-routes setup,
    * `Plug.Conn` and `Phoenix.ConnTest` imports,
    * a `setup_all` that verifies the provider's env vars,
    * a `setup` that loads config and clears ETS.
  """
  defmacro __using__(opts) do
    provider = Keyword.get(opts, :provider, :openai)
    tags = Keyword.get(opts, :tags, [:"integration_#{provider}"])

    quote do
      use ExUnit.Case
      @moduletag :integration

      unquote(
        for tag <- tags do
          quote do
            @moduletag unquote(tag)
          end
        end
      )

      @endpoint ShhAiWeb.Endpoint
      use ShhAiWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest

      setup_all do
        ShhAi.IntegrationCase.verify_provider!(unquote(provider))
      end

      setup _context do
        ShhAi.IntegrationCase.setup_test()
      end
    end
  end

  @doc """
  Asserts that the required env vars for `provider` are set. Raises
  with a clear, actionable error message otherwise. Called from the
  `setup_all` injected by `__using__/1`.
  """
  @spec verify_provider!(:openai | :anthropic | :ollama) :: :ok
  def verify_provider!(provider) do
    case provider do
      :openai ->
        if !env_enabled?("PROVIDER_OPENAI_1_ENABLED") or
             !env_present?("PROVIDER_OPENAI_1_API_KEY") do
          raise """
          Integration tests for :openai require PROVIDER_OPENAI_1_ENABLED=true \
          and PROVIDER_OPENAI_1_API_KEY. See docs/testing.md.
          """
        end

      :anthropic ->
        if !env_enabled?("PROVIDER_ANTHROPIC_1_ENABLED") or
             !env_present?("PROVIDER_ANTHROPIC_1_API_KEY") do
          raise """
          Integration tests for :anthropic require PROVIDER_ANTHROPIC_1_ENABLED=true \
          and PROVIDER_ANTHROPIC_1_API_KEY. See docs/testing.md.
          """
        end

      :ollama ->
        if !env_enabled?("PROVIDER_OLLAMA_1_ENABLED") do
          raise """
          Integration tests for :ollama require PROVIDER_OLLAMA_1_ENABLED=true. \
          See docs/testing.md.
          """
        end

      other ->
        raise ArgumentError,
              "Unknown integration provider #{inspect(other)} (expected :openai, :anthropic, or :ollama)"
    end

    :ok
  end

  @doc """
  Per-test setup. Reloads `Config` so persistent_term reflects the
  current env, clears the ETS conversation store, and returns a fresh
  `Phoenix.ConnTest.build_conn/0` as `conn`.
  """
  @spec setup_test() :: {:ok, keyword()}
  def setup_test do
    ShhAi.Config.load()
    ShhAi.ConversationCase.setup_ets()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp env_enabled?(name), do: System.get_env(name) == "true"

  defp env_present?(name) do
    case System.get_env(name) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
