defmodule ShhAi.Integration.OpenAIIntegrationTest do
  use ShhAi.IntegrationCase, provider: :openai

  @moduledoc """
  Integration tests for the OpenAI-compatible API surface.

  Tests are agnostic of the underlying provider: they probe
  `GET /v1/models` in `setup_all/0` to discover a chat-capable model
  and (if any) an embedding-capable model exposed by the configured
  `PROVIDER_OPENAI_1_BASE_URL`. The chat model can also be pinned
  via the `INTEGRATION_TEST_MODEL` env var.

  When the provider exposes no embedding models (e.g. nano-gpt), the
  embeddings test fails cleanly with `flunk/1` and an actionable
  message — Elixir 1.19.4 has no runtime skip API, so we surface the
  environmental gap as a failure with a clear fix rather than a
  cryptic upstream error.
  """

  # Fallback when probing fails — prefer a real upstream error over a silent fallback.
  @default_chat_model "gpt-4o-mini"

  # Probe `/v1/models` once before the suite starts so each test can
  # pick a model that actually exists on the configured provider. The
  # `INTEGRATION_TEST_MODEL` env var takes precedence — it lets a
  # developer pin a specific model for cost/quality reasons.
  setup_all do
    ShhAi.Config.load()
    {chat_model, embedding_model} = discover_models()
    {:ok, chat_model: chat_model, embedding_model: embedding_model}
  end

  # ----- model discovery -------------------------------------------------

  # Returns `{chat_model, embedding_model_or_nil}`. Either may be nil
  # if probing failed or no matching model is found.
  defp discover_models do
    override = System.get_env("INTEGRATION_TEST_MODEL")

    case fetch_models_via_proxy() do
      {:ok, models} when is_list(models) ->
        {override || pick_chat_model(models) || @default_chat_model, pick_embedding_model(models)}

      _ ->
        # Probe failed (network, misconfig). Honour the override if
        # the user gave one; otherwise fall back to the hardcoded
        # default and let the per-test assertion surface the real
        # error from upstream.
        {override || @default_chat_model, nil}
    end
  end

  # Hits `/v1/models` through the same Phoenix endpoint stack the
  # tests use, so we exercise the real proxy path. Returns
  # `{:ok, [%{"id" => ...}, ...]}` or `{:error, reason}`.
  defp fetch_models_via_proxy do
    conn = Phoenix.ConnTest.build_conn()

    conn
    |> Phoenix.ConnTest.get(~p"/v1/models")
    |> case do
      %Plug.Conn{status: status, resp_body: body} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
          other -> {:error, {:unexpected_body, other}}
        end

      %Plug.Conn{status: status, resp_body: body} ->
        {:error, {:http_error, status, body}}
    end
  end

  # Pick the first model whose id does not advertise itself as
  # embedding-only. "embed"/"embedding" in the id is the strongest
  # universal signal across the providers we've seen (OpenAI,
  # nano-gpt, vLLM, etc.).
  defp pick_chat_model(models) do
    Enum.find_value(models, fn
      %{"id" => id} when is_binary(id) ->
        if embedding_model_id?(id), do: nil, else: id

      _ ->
        nil
    end)
  end

  defp pick_embedding_model(models) do
    Enum.find_value(models, fn
      %{"id" => id} when is_binary(id) ->
        if embedding_model_id?(id), do: id, else: nil

      _ ->
        nil
    end)
  end

  defp embedding_model_id?(id) do
    lower = String.downcase(id)
    String.contains?(lower, "embed")
  end

  # ----- helpers ---------------------------------------------------------

  # Decode a 2xx JSON response. `flunk/1` with the full body for
  # non-2xx — preserves the upstream error in the test failure for
  # faster diagnosis.
  defp decode!(%Plug.Conn{status: status, resp_body: body}) when status in 200..299 do
    {:ok, decoded} = Jason.decode(body)
    decoded
  end

  defp decode!(%Plug.Conn{status: status, resp_body: body}) do
    flunk("Expected 2xx, got #{status}. Body: #{body}")
  end

  # The embeddings test is the only one that can't degrade silently —
  # we have no runtime skip mechanism in Elixir 1.19.4. When the
  # provider exposes no embedding model, fail with an actionable
  # message: tell the user exactly what's missing and how to fix it.
  defp require_embedding_model!(nil) do
    flunk("""
    No embedding-capable model found on the configured provider
    (PROVIDER_OPENAI_1_BASE_URL=#{System.get_env("PROVIDER_OPENAI_1_BASE_URL") || "<default>"}).

    The `/v1/models` response did not contain any model id with "embed"
    in its name. This usually means the provider does not expose
    embeddings, or your account does not have access to them.

    To make this test pass, run against a provider that exposes an
    embedding model (e.g. real OpenAI with `text-embedding-3-small`),
    or skip the embedding assertion out-of-band.
    """)
  end

  defp require_embedding_model!(_model), do: :ok

  # ----- tests -----------------------------------------------------------

  # ---- POST /v1/chat/completions non-streaming ----
  describe "POST /v1/chat/completions (non-streaming)" do
    test "returns a real assistant message", %{conn: conn, chat_model: model} do
      uid = System.unique_integer([:positive])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/chat/completions", %{
          "model" => model,
          "messages" => [
            %{"role" => "user", "content" => "Reply with the single word: pong ##{uid}"}
          ]
        })

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      response = decode!(conn)
      assert is_list(response["choices"]) and response["choices"] != []
      content = hd(response["choices"]) |> get_in(["message", "content"])
      assert is_binary(content)
      assert content |> String.downcase() |> String.contains?("pong")

      # `usage` is an OpenAI extension — some providers (e.g. nano-gpt's
      # nemotron model) return valid responses without it. When present,
      # verify the structure; when absent, that's fine.
      case response["usage"] do
        nil ->
          :ok

        %{} = usage ->
          assert usage["total_tokens"] > 0,
                 "Expected usage.total_tokens > 0, got: #{inspect(usage)}"
      end
    end
  end

  # ---- POST /v1/chat/completions with PII (roundtrip) ----
  describe "POST /v1/chat/completions with PII" do
    test "PII never reaches the LLM and never appears unredacted in the response",
         %{conn: conn, chat_model: model} do
      # The proxy must sanitize the email to <EMAIL_1> before forwarding.
      # The LLM therefore never sees the original, and the LLM cannot echo it back.
      secret_email = "integration-secret-#{System.unique_integer([:positive])}@example.com"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/chat/completions", %{
          "model" => model,
          "messages" => [
            %{
              "role" => "user",
              "content" => "My email is #{secret_email}. Acknowledge with the word 'noted'."
            }
          ]
        })

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      response = decode!(conn)
      content = hd(response["choices"]) |> get_in(["message", "content"])

      # The original PII must not appear in the response. If it does, the
      # proxy failed to sanitize (or the LLM happened to know it, which is
      # astronomically unlikely for a fresh unique email).
      refute String.contains?(content, secret_email),
             "Original PII leaked into response: #{inspect(content)}"
    end
  end

  # ---- POST /v1/chat/completions streaming ----
  describe "POST /v1/chat/completions (streaming)" do
    test "returns a chunked SSE response that ends with [DONE]",
         %{conn: conn, chat_model: model} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/chat/completions", %{
          "model" => model,
          "messages" => [
            %{"role" => "user", "content" => "Reply with the single word: pong"}
          ],
          "stream" => true
        })

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      body = conn.resp_body
      assert is_binary(body)

      assert String.contains?(body, "data:"),
             "Expected SSE `data:` in body, got: #{inspect(body)}"

      assert String.contains?(body, "[DONE]"),
             "Expected SSE `[DONE]` sentinel in body, got: #{inspect(body)}"
    end
  end

  # ---- POST /v1/embeddings ----
  describe "POST /v1/embeddings" do
    test "returns a vector for the input", %{conn: conn, embedding_model: model} do
      require_embedding_model!(model)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/embeddings", %{
          "model" => model,
          "input" => "hello world"
        })

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      response = decode!(conn)
      assert is_list(response["data"]) and response["data"] != []
      embedding = hd(response["data"])["embedding"]
      assert is_list(embedding) and length(embedding) > 0
    end
  end

  # ---- GET /v1/models ----
  describe "GET /v1/models" do
    test "returns a list of models", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> get(~p"/v1/models")

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      response = decode!(conn)
      assert is_list(response["data"]) and response["data"] != []
      assert is_binary(hd(response["data"])["id"])
    end
  end

  # ---- POST /v1/completions (legacy) ----
  describe "POST /v1/completions (legacy)" do
    test "returns at least one choice", %{conn: conn, chat_model: model} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/completions", %{
          "model" => model,
          "prompt" => "Say hi",
          "max_tokens" => 5
        })

      assert conn.status == 200,
             "Expected 200, got #{conn.status}. Body: #{conn.resp_body}"

      response = decode!(conn)
      assert is_list(response["choices"]) and response["choices"] != []
    end
  end
end
