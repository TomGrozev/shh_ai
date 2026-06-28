defmodule ShhAi.Integration.OllamaIntegrationTest do
  use ShhAi.IntegrationCase, provider: :ollama

  @default_model "llama3.2"

  defp test_model, do: System.get_env("INTEGRATION_TEST_MODEL", @default_model)

  defp decode!(%Plug.Conn{status: status, resp_body: body} = _conn) when status in 200..299 do
    {:ok, decoded} = Jason.decode(body)
    decoded
  end

  defp decode!(%Plug.Conn{status: status, resp_body: body}) do
    flunk("Expected 2xx, got #{status}. Body: #{body}")
  end

  # If the model isn't pulled, Ollama returns 404 with an error body.
  # Skip those tests gracefully with a clear message instead of failing.
  defp skip_unless_model_available!(%Plug.Conn{status: status, resp_body: body} = _conn) do
    case status do
      s when s in 200..299 ->
        :ok

      404 ->
        if String.contains?(body, "not found") or String.contains?(body, "pull") do
          flunk("Ollama model not available: #{body}")
        else
          flunk("Ollama returned 404: #{body}")
        end

      other ->
        flunk("Ollama returned #{other}: #{body}")
    end
  end

  describe "GET /api/tags" do
    test "returns a list of pulled models", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get(~p"/api/tags")

      assert conn.status == 200
      response = decode!(conn)
      assert is_list(response["models"])

      # `models` may be empty if the user hasn't pulled any models —
      # that's still a valid response, so don't assert non-empty.
    end
  end

  describe "POST /api/chat (non-streaming)" do
    test "returns a real assistant message", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/chat", %{
          "model" => test_model(),
          "messages" => [
            %{"role" => "user", "content" => "Reply with the single word: pong"}
          ],
          "stream" => false
        })

      skip_unless_model_available!(conn)
      response = decode!(conn)
      assert is_map(response)
      content = get_in(response, ["message", "content"])
      assert is_binary(content)
      assert content |> String.downcase() |> String.contains?("pong")
    end
  end

  describe "POST /api/generate (non-streaming)" do
    test "returns a completion string", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/generate", %{
          "model" => test_model(),
          "prompt" => "Reply with the single word: pong",
          "stream" => false
        })

      skip_unless_model_available!(conn)
      response = decode!(conn)
      assert is_binary(response["response"])
      assert response["response"] |> String.downcase() |> String.contains?("pong")
    end
  end
end
