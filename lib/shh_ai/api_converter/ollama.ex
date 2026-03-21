defmodule ShhAi.ApiConverter.Ollama do
  @moduledoc """
  Ollama API format converter.
  Converts between OpenAI format (canonical) and Ollama API format.
  """

  @behaviour ShhAi.ApiConverter

  # Request conversion: Ollama -> OpenAI
  @impl true
  def to_openai_request(headers, %{"messages" => messages} = request, _path) do
    # Ollama chat format is similar to OpenAI, but with some differences
    body =
      %{
        "model" => request["model"],
        "messages" => messages,
        "stream" => request["stream"],
        "temperature" => request["options"]["temperature"],
        "top_p" => request["options"]["top_p"],
        "max_tokens" => request["options"]["num_predict"]
      }
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Map.new()

    {headers, body}
  end

  def to_openai_request(headers, %{"prompt" => _prompt} = request, "/api/generate") do
    # Convert Ollama generate to OpenAI chat completion
    body =
      %{
        "model" => request["model"],
        "messages" => [%{"role" => "user", "content" => request["prompt"]}],
        "stream" => request["stream"],
        "max_tokens" => request["options"]["num_predict"],
        "temperature" => request["options"]["temperature"]
      }
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Map.new()

    {headers, body}
  end

  def to_openai_request(headers, body, _path), do: {headers, body}

  # Request conversion: OpenAI -> Ollama
  @impl true
  def from_openai_request(headers, %{"messages" => messages} = request, "/api/chat") do
    ollama_request = %{
      "model" => request["model"],
      "messages" => messages,
      "stream" => request["stream"] || false
    }

    # Build options from OpenAI parameters
    options = %{}

    options =
      case request["temperature"] do
        nil -> options
        temp -> Map.put(options, "temperature", temp)
      end

    options =
      case request["top_p"] do
        nil -> options
        top_p -> Map.put(options, "top_p", top_p)
      end

    options =
      case request["max_tokens"] do
        nil -> options
        max_tokens -> Map.put(options, "num_predict", max_tokens)
      end

    ollama_request =
      if map_size(options) > 0 do
        Map.put(ollama_request, "options", options)
      else
        ollama_request
      end

    {headers, ollama_request}
  end

  def from_openai_request(headers, %{"messages" => messages} = request, "/api/generate") do
    # Convert chat to generate format (use last user message as prompt)
    last_user_message =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "user" end)

    prompt = if last_user_message, do: last_user_message["content"], else: ""

    body =
      %{
        "model" => request["model"],
        "prompt" => prompt,
        "stream" => request["stream"] || false
      }

    {headers, body}
  end

  def from_openai_request(headers, body, _path), do: {headers, body}

  # Response conversion: Ollama -> OpenAI
  @impl true
  def to_openai_response(%{"message" => %{"content" => content}} = response, "/api/chat") do
    %{
      "id" => generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => response["done_reason"]
        }
      ],
      "usage" => map_usage_to_openai(response)
    }
  end

  def to_openai_response(%{"response" => content} = response, "/api/generate") do
    %{
      "id" => generate_id("chatcmpl"),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => response["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => map_usage_to_openai(response)
    }
  end

  def to_openai_response(response, path) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> to_openai_response(decoded, path)
      {:error, _} -> response
    end
  end

  def to_openai_response(response, _path), do: response

  # Response conversion: OpenAI -> Ollama
  @impl true
  def from_openai_response(%{"choices" => [_ | _] = choices} = response, "/api/chat") do
    choice = List.first(choices)
    message = choice["message"]

    %{
      "model" => response["model"],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => %{
        "role" => "assistant",
        "content" => message["content"] || ""
      },
      "done" => true,
      "done_reason" => choice["finish_reason"]
    }
    |> maybe_add_usage(response["usage"])
  end

  def from_openai_response(%{"choices" => [_ | _] = choices} = response, "/api/generate") do
    choice = List.first(choices)
    message = choice["message"]

    %{
      "model" => response["model"],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "response" => message["content"] || "",
      "done" => true
    }
    |> maybe_add_usage(response["usage"])
  end

  def from_openai_response(response, path) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, decoded} -> from_openai_response(decoded, path)
      {:error, _} -> response
    end
  end

  def from_openai_response(response, _path), do: response

  # Streaming conversion: Ollama -> OpenAI
  @impl true
  def to_openai_stream_chunk(chunk, path) do
    case Jason.decode(chunk) do
      {:ok, decoded} -> handle_ollama_stream_event(decoded, path)
      {:error, _} -> [chunk]
    end
  end

  # Streaming conversion: OpenAI -> Ollama
  @impl true
  def from_openai_stream_chunk(chunk, _path) do
    case parse_sse_chunk(chunk) do
      {:data, data} ->
        case data do
          "[DONE]" ->
            :done

          _ ->
            case Jason.decode(data) do
              {:ok, decoded} -> handle_openai_stream_event(decoded)
              {:error, _} -> [chunk]
            end
        end

      :done ->
        :done

      {:error, _} ->
        [chunk]
    end
  end

  # Path conversion
  @impl true
  def to_openai_path("/api/chat"), do: "/v1/chat/completions"
  def to_openai_path("/api/generate"), do: "/v1/chat/completions"
  def to_openai_path("/api/embeddings"), do: "/v1/embeddings"
  def to_openai_path("/api/tags"), do: "/v1/models"
  def to_openai_path(_path), do: "/v1/chat/completions"

  @impl true
  def from_openai_path("/v1/chat/completions"), do: "/api/chat"
  def from_openai_path("/v1/completions"), do: "/api/generate"
  def from_openai_path("/v1/embeddings"), do: "/api/embeddings"
  def from_openai_path("/v1/models"), do: "/api/tags"
  def from_openai_path(_path), do: "/api/chat"

  @impl true
  def get_path_type("/api/chat"), do: {:chat, "/api/chat"}
  def get_path_type("/api/generate"), do: {:chat, "/api/generate"}
  def get_path_type("/api/embeddings"), do: {:embeddings, "/api/embeddings"}
  def get_path_type("/api/tags"), do: {:models, "/api/tags"}
  def get_path_type(path), do: {:other, path}

  # Private helpers

  defp map_usage_to_openai(%{"prompt_eval_count" => prompt, "eval_count" => completion}) do
    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => prompt + completion
    }
  end

  defp map_usage_to_openai(%{"eval_count" => completion}) do
    %{
      "prompt_tokens" => 0,
      "completion_tokens" => completion,
      "total_tokens" => completion
    }
  end

  defp map_usage_to_openai(_),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  defp maybe_add_usage(response, nil), do: response

  defp maybe_add_usage(response, usage) do
    response
    |> Map.put("prompt_eval_count", usage["prompt_tokens"] || 0)
    |> Map.put("eval_count", usage["completion_tokens"] || 0)
  end

  defp generate_id(prefix) do
    random_suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    "#{prefix}-#{random_suffix}"
  end

  # SSE parsing helpers

  defp parse_sse_chunk(chunk) do
    cond do
      String.contains?(chunk, "[DONE]") ->
        :done

      String.starts_with?(chunk, "data:") ->
        case String.split(chunk, "data:", parts: 2) do
          [_, data] -> {:data, String.trim(data)}
          _ -> {:error, :invalid_format}
        end

      true ->
        {:error, :invalid_format}
    end
  end

  defp handle_ollama_stream_event(
         %{"message" => %{"content" => content}} = event,
         "/api/chat"
       ) do
    openai_chunk = %{
      "id" => Map.get(event, :id, generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => event["model"],
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"content" => content},
          "finish_reason" => nil
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data]
  end

  defp handle_ollama_stream_event(%{"response" => content} = event, "/api/generate") do
    openai_chunk = %{
      "id" => Map.get(event, :id, generate_id("chatcmpl")),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => event["model"],
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"content" => content},
          "finish_reason" => nil
        }
      ]
    }

    data = "data: #{Jason.encode!(openai_chunk)}\n\n"
    [data]
  end

  defp handle_ollama_stream_event(%{"done" => true}, _path), do: ["data: [DONE]\n\n"]

  defp handle_ollama_stream_event(_event, _path), do: []

  defp handle_openai_stream_event(%{"choices" => choices} = event) do
    choice = List.first(choices, %{})
    delta = Map.get(choice, "delta", %{})

    ollama_chunk =
      cond do
        Map.get(delta, "content") != nil ->
          %{
            "model" => Map.get(event, :model, "llama3"),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "message" => %{
              "role" => "assistant",
              "content" => delta["content"]
            },
            "done" => false
          }

        Map.get(delta, "role") == "assistant" ->
          nil

        true ->
          nil
      end

    case ollama_chunk do
      nil ->
        []

      chunk ->
        data = "#{Jason.encode!(chunk)}\n"
        [data]
    end
  end

  defp handle_openai_stream_event(_event) do
    []
  end
end
