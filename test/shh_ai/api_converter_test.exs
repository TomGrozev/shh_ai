defmodule ShhAi.ApiConverterTest do
  use ExUnit.Case, async: true

  alias ShhAi.ApiConverter

  describe "get_converter/1" do
    test "returns OpenAI converter for :openai" do
      assert ApiConverter.get_converter(:openai) == ShhAi.ApiConverter.OpenAI
    end

    test "returns Anthropic converter for :anthropic" do
      assert ApiConverter.get_converter(:anthropic) == ShhAi.ApiConverter.Anthropic
    end

    test "returns Ollama converter for :ollama" do
      assert ApiConverter.get_converter(:ollama) == ShhAi.ApiConverter.Ollama
    end
  end

  describe "get_target_path/3" do
    test "returns same path for OpenAI to OpenAI" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for OpenAI to Anthropic" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for OpenAI to Ollama" do
      path = ApiConverter.get_target_path("/v1/chat/completions", :openai, :ollama)
      assert path == "/api/chat"
    end

    test "returns OpenAI path for Anthropic to OpenAI" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for Anthropic to Anthropic" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for Anthropic to Ollama" do
      path = ApiConverter.get_target_path("/v1/messages", :anthropic, :ollama)
      assert path == "/api/chat"
    end

    test "returns OpenAI path for Ollama to OpenAI" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns Anthropic path for Ollama to Anthropic" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :anthropic)
      assert path == "/v1/messages"
    end

    test "returns Ollama path for Ollama to Ollama" do
      path = ApiConverter.get_target_path("/api/chat", :ollama, :ollama)
      assert path == "/api/chat"
    end
  end

  describe "get_path_info/2" do
    test "returns chat type for OpenAI chat completions" do
      {:chat, path} = ApiConverter.get_path_info("/v1/chat/completions", :openai)
      assert path == "/v1/chat/completions"
    end

    test "returns embeddings type for OpenAI embeddings" do
      {:embeddings, path} = ApiConverter.get_path_info("/v1/embeddings", :openai)
      assert path == "/v1/embeddings"
    end

    test "returns models type for OpenAI models" do
      {:models, path} = ApiConverter.get_path_info("/v1/models", :openai)
      assert path == "/v1/models"
    end

    test "returns chat type for Anthropic messages" do
      {:chat, path} = ApiConverter.get_path_info("/v1/messages", :anthropic)
      assert path == "/v1/messages"
    end

    test "returns chat type for Ollama chat" do
      {:chat, path} = ApiConverter.get_path_info("/api/chat", :ollama)
      assert path == "/api/chat"
    end

    test "returns chat type for Ollama generate" do
      {:chat, path} = ApiConverter.get_path_info("/api/generate", :ollama)
      assert path == "/api/generate"
    end

    test "returns embeddings type for Ollama embeddings" do
      {:embeddings, path} = ApiConverter.get_path_info("/api/embeddings", :ollama)
      assert path == "/api/embeddings"
    end

    test "returns models type for Ollama tags" do
      {:models, path} = ApiConverter.get_path_info("/api/tags", :ollama)
      assert path == "/api/tags"
    end
  end
end
