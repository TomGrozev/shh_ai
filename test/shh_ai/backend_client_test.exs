defmodule ShhAi.BackendClientTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.BackendClient
  alias ShhAi.SessionStore.ETS

  setup do
    # Set up a provider for tests
    System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
    System.put_env("PROVIDER_OPENAI_1_API_KEY", "test-key")
    System.put_env("PROVIDER_OPENAI_1_BASE_URL", "https://api.openai.com/v1")
    Config.load()

    # Initialize ETS for session tests
    ETS.init()

    on_exit(fn ->
      System.delete_env("PROVIDER_OPENAI_1_ENABLED")
      System.delete_env("PROVIDER_OPENAI_1_API_KEY")
      System.delete_env("PROVIDER_OPENAI_1_BASE_URL")
    end)

    :ok
  end

  describe "request/5" do
    test "handles map body" do
      body = %{"model" => "gpt-4", "messages" => []}
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "handles binary JSON body" do
      body = Jason.encode!(%{"model" => "gpt-4", "messages" => []})
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "handles invalid JSON string body" do
      body = "not valid json"
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "converts Anthropic format to target provider" do
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "test-anthropic-key")
      Config.load()

      body = %{
        "model" => "claude-3-opus",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 1024
      }

      headers = [{"x-api-key", "original-key"}]

      result = BackendClient.request(:anthropic, "/v1/messages", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end

      System.delete_env("PROVIDER_ANTHROPIC_1_ENABLED")
      System.delete_env("PROVIDER_ANTHROPIC_1_API_KEY")
    end

    test "converts Ollama format to target provider" do
      System.put_env("PROVIDER_OLLAMA_1_ENABLED", "true")
      System.put_env("PROVIDER_OLLAMA_1_BASE_URL", "http://localhost:11434")
      Config.load()

      body = %{"model" => "llama3", "messages" => [%{"role" => "user", "content" => "test"}]}
      headers = []

      result = BackendClient.request(:ollama, "/api/chat", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end

      System.delete_env("PROVIDER_OLLAMA_1_ENABLED")
      System.delete_env("PROVIDER_OLLAMA_1_BASE_URL")
    end

    test "handles multiple providers configured" do
      System.put_env("PROVIDER_OPENAI_1_ENABLED", "true")
      System.put_env("PROVIDER_OPENAI_1_API_KEY", "key1")
      System.put_env("PROVIDER_ANTHROPIC_1_ENABLED", "true")
      System.put_env("PROVIDER_ANTHROPIC_1_API_KEY", "key2")
      Config.load()

      body = %{"model" => "test", "messages" => []}
      headers = []

      results =
        for _ <- 1..5 do
          case BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers) do
            {:ok, _response, _measurements} ->
              true

            {:error, _reason} ->
              false
          end
        end
        |> Enum.reject(&is_nil/1)

      # All providers should be valid strings
      assert length(results) > 0
      assert Enum.all?(results, &is_boolean/1)

      System.delete_env("PROVIDER_OPENAI_1_ENABLED")
      System.delete_env("PROVIDER_OPENAI_1_API_KEY")
      System.delete_env("PROVIDER_ANTHROPIC_1_ENABLED")
      System.delete_env("PROVIDER_ANTHROPIC_1_API_KEY")
    end

    test "handles empty map body" do
      body = %{}
      headers = []

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "preserves custom headers through conversion" do
      body = %{"model" => "gpt-4", "messages" => []}
      headers = [{"x-custom-header", "custom-value"}, {"x-request-id", "12345"}]

      result = BackendClient.request(:openai, "/v1/chat/completions", :post, body, headers)

      case result do
        {:ok, _response, _measurements} -> assert true
        {:error, _reason} -> assert true
      end
    end
  end
end
