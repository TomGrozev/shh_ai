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
    * `:ollama` — `PROVIDER_OLLAMA_1_ENABLED=true` and
      `PROVIDER_OLLAMA_1_API_KEY` (non-empty).

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

  # The gate token the integration suite configures and sends; it is not a
  # real credential, just a value shared between setup and requests.
  @gate_token "integration-gate-token"

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
        require_enabled_and_key!(
          :openai,
          "PROVIDER_OPENAI_1_ENABLED",
          "PROVIDER_OPENAI_1_API_KEY"
        )

      :anthropic ->
        require_enabled_and_key!(
          :anthropic,
          "PROVIDER_ANTHROPIC_1_ENABLED",
          "PROVIDER_ANTHROPIC_1_API_KEY"
        )

      :ollama ->
        require_enabled_and_key!(
          :ollama,
          "PROVIDER_OLLAMA_1_ENABLED",
          "PROVIDER_OLLAMA_1_API_KEY"
        )

      other ->
        raise ArgumentError,
              "Unknown integration provider #{inspect(other)} (expected :openai, :anthropic, or :ollama)"
    end

    :ok
  end

  defp require_enabled_and_key!(provider, enabled_var, key_var) do
    if env_enabled?(enabled_var) and env_present?(key_var) do
      :ok
    else
      raise """
      Integration tests for #{inspect(provider)} require #{enabled_var}=true \
      and #{key_var}. See docs/testing.md.
      """
    end
  end

  @doc """
  Per-test setup. Reloads `Config` so persistent_term reflects the
  current env, clears the ETS conversation store, and returns a fresh
  `Phoenix.ConnTest.build_conn/0` — carrying the proxy gate token — as
  `conn`.
  """
  @spec setup_test() :: {:ok, keyword()}
  def setup_test do
    System.put_env("PROXY_API_KEYS", @gate_token)
    ShhAi.Config.load()
    ShhAi.ConversationCase.setup_ets()

    {name, value} = gate_authorization()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header(name, value)

    {:ok, conn: conn}
  end

  @doc """
  The `authorization` header value the integration suite sends to the proxy.

  Every proxy-touching integration request must carry it (see issue #55).
  """
  @spec gate_authorization() :: {String.t(), String.t()}
  def gate_authorization, do: {"authorization", "Bearer #{@gate_token}"}

  defp env_enabled?(name), do: System.get_env(name) == "true"

  defp env_present?(name) do
    case System.get_env(name) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
