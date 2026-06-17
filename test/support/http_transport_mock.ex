defmodule ShhAi.BackendClient.HTTPTransportMock do
  @moduledoc """
  Mock HTTP transport for tests.

  Returns canned responses based on the URL pattern.
  Configure via:
      Application.put_env(:shh_ai, :http_client, ShhAi.BackendClient.HTTPTransportMock)
  """

  @openai_response %{
    "id" => "chatcmpl-test",
    "object" => "chat.completion",
    "created" => 1_700_000_000,
    "model" => "gpt-4",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{"role" => "assistant", "content" => "Hello!"},
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
  }

  @anthropic_response %{
    "id" => "msg_test",
    "type" => "message",
    "role" => "assistant",
    "content" => [%{"type" => "text", "text" => "Hello!"}],
    "model" => "claude-3-opus",
    "stop_reason" => "end_turn",
    "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
  }

  @ollama_response %{
    "model" => "llama3",
    "message" => %{"role" => "assistant", "content" => "Hello!"},
    "done" => true
  }

  def do_request(_method, url, _body, _headers, _timeout) do
    body =
      cond do
        String.contains?(url, "anthropic") -> @anthropic_response
        String.contains?(url, "ollama") or String.contains?(url, "11434") -> @ollama_response
        true -> @openai_response
      end

    {:ok,
     %Req.Response{
       status: 200,
       headers: [{"content-type", "application/json"}],
       body: body
     }}
  end
end
