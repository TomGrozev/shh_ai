defmodule ShhAi.Integration.CrossProviderIntegrationTest do
  @moduledoc """
  Tests that exercise the proxy's source/target cross-conversion: an
  OpenAI-format request gets forwarded to whichever target provider is
  configured, and the response is converted back to OpenAI format.

  Requires both `PROVIDER_OPENAI_1_API_KEY` and `PROVIDER_ANTHROPIC_1_API_KEY`
  to be set. Tagged `:integration_cross_provider` — run with:

      mix test --only integration_cross_provider

  Uses `flunk` (not skip) when env vars are missing, because Elixir 1.19.4
  has no in-body skip API (`ExUnit.Callbacks.skip/1` does not exist).
  """

  use ShhAi.IntegrationCase, provider: :openai, tags: [:integration_cross_provider]

  @default_model "gpt-4o-mini"

  defp test_model, do: System.get_env("INTEGRATION_TEST_MODEL", @default_model)

  defp decode!(%Plug.Conn{status: status, resp_body: body} = _conn) when status in 200..299 do
    {:ok, decoded} = Jason.decode(body)
    decoded
  end

  defp decode!(%Plug.Conn{status: status, resp_body: body}) do
    flunk("Expected 2xx, got #{status}. Body: #{body}")
  end

  defp both_providers_configured? do
    openai_key = System.get_env("PROVIDER_OPENAI_1_API_KEY")
    anthropic_key = System.get_env("PROVIDER_ANTHROPIC_1_API_KEY")

    System.get_env("PROVIDER_OPENAI_1_ENABLED") == "true" and
      is_binary(openai_key) and openai_key != "" and
      System.get_env("PROVIDER_ANTHROPIC_1_ENABLED") == "true" and
      is_binary(anthropic_key) and anthropic_key != ""
  end

  describe "OpenAI source → randomly selected target → OpenAI response" do
    test "POST /v1/chat/completions returns a valid OpenAI-format response", %{conn: conn} do
      unless both_providers_configured?() do
        flunk(
          "Cross-provider tests require BOTH PROVIDER_OPENAI_1_API_KEY and PROVIDER_ANTHROPIC_1_API_KEY."
        )
      end

      uid = System.unique_integer([:positive])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/chat/completions", %{
          "model" => test_model(),
          "messages" => [
            %{"role" => "user", "content" => "Reply with the single word: pong ##{uid}"}
          ]
        })

      assert conn.status == 200
      response = decode!(conn)

      # The response MUST be in OpenAI format regardless of which
      # target provider was selected. If the proxy fails to convert,
      # the client (an OpenAI client) would not be able to parse it.
      assert is_list(response["choices"])
      assert response["choices"] != []
      content = hd(response["choices"]) |> get_in(["message", "content"])
      assert is_binary(content)
      assert content |> String.downcase() |> String.contains?("pong")
    end

    test "OpenAI request body parameters (temperature, max_tokens, top_p) survive conversion",
         %{conn: conn} do
      unless both_providers_configured?() do
        flunk(
          "Cross-provider tests require BOTH PROVIDER_OPENAI_1_API_KEY and PROVIDER_ANTHROPIC_1_API_KEY."
        )
      end

      # Use a request body with extra OpenAI-format parameters. The
      # proxy must convert these to the target provider's equivalent
      # fields. We just assert that the response is well-formed — a
      # roundtrip failure would manifest as a 4xx/5xx.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/chat/completions", %{
          "model" => test_model(),
          "messages" => [
            %{"role" => "user", "content" => "Say hi"}
          ],
          "temperature" => 0.2,
          "top_p" => 0.9,
          "max_tokens" => 10
        })

      assert conn.status == 200
      response = decode!(conn)
      assert is_list(response["choices"])
      assert response["choices"] != []
    end
  end
end
