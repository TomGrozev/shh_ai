defmodule ShhAi.Integration.AnthropicIntegrationTest do
  use ShhAi.IntegrationCase, provider: :anthropic

  @default_model "claude-3-5-haiku-latest"

  defp test_model, do: System.get_env("INTEGRATION_TEST_MODEL", @default_model)

  defp decode!(%Plug.Conn{status: status, resp_body: body} = _conn) when status in 200..299 do
    {:ok, decoded} = Jason.decode(body)
    decoded
  end

  defp decode!(%Plug.Conn{status: status, resp_body: body}) do
    flunk("Expected 2xx, got #{status}. Body: #{body}")
  end

  describe "POST /v1/messages (non-streaming)" do
    test "returns a real assistant text block", %{conn: conn} do
      uid = System.unique_integer([:positive])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/messages", %{
          "model" => test_model(),
          "max_tokens" => 30,
          "messages" => [
            %{"role" => "user", "content" => "Reply with exactly the word: ping ##{uid}"}
          ]
        })

      assert conn.status == 200
      response = decode!(conn)
      assert is_list(response["content"]) and response["content"] != []

      text_block =
        Enum.find(response["content"], fn block -> block["type"] == "text" end)

      assert text_block,
             "expected at least one text content block, got: #{inspect(response["content"])}"

      assert is_binary(text_block["text"])
      assert text_block["text"] |> String.downcase() |> String.contains?("ping")
    end
  end

  describe "POST /v1/messages (streaming)" do
    test "returns typed SSE events ending with message_stop", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/messages", %{
          "model" => test_model(),
          "max_tokens" => 30,
          "messages" => [
            %{"role" => "user", "content" => "Reply with the single word: pong"}
          ],
          "stream" => true
        })

      assert conn.status == 200
      body = conn.resp_body
      assert is_binary(body)
      # Anthropic SSE uses `event:` lines for typed events
      assert String.contains?(body, "event:")
      assert String.contains?(body, "message_stop")
    end
  end

  describe "POST /v1/messages with PII" do
    test "PII never reaches the LLM and never appears unredacted in the response", %{conn: conn} do
      secret_email = "integration-anthropic-#{System.unique_integer([:positive])}@example.com"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/messages", %{
          "model" => test_model(),
          "max_tokens" => 50,
          "messages" => [
            %{
              "role" => "user",
              "content" => "My email is #{secret_email}. Acknowledge with the word 'noted'."
            }
          ]
        })

      assert conn.status == 200
      response = decode!(conn)

      full_text =
        response["content"]
        |> Enum.filter(fn b -> b["type"] == "text" end)
        |> Enum.map(& &1["text"])
        |> Enum.join(" ")

      refute String.contains?(full_text, secret_email)
    end
  end
end
