defmodule ShhAi.ProviderClient.StreamHandler.FinalizeTest do
  @moduledoc """
  Tests for the (handle, backend_start) signature of StreamHandler.finalize/2.
  """
  use ExUnit.Case, async: false

  alias ShhAi.ApiConverter
  alias ShhAi.Conversation
  alias ShhAi.Metrics
  alias ShhAi.PIIPipeline.RestoreState
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle

  setup do
    ShhAi.ConversationCase.setup_ets()
    :ok
  end

  defp build_handle(test_pid, conversation, streaming \\ true) do
    request_context = %RequestContext{
      source_provider: :openai,
      target_provider: :openai,
      source_path: "/v1/chat/completions",
      target_path: "/v1/chat/completions",
      method: :post,
      config: %{name: "gpt-4", base_url: "http://localhost:9999/v1", timeout: 60_000},
      source_converter: ApiConverter.get_converter(:openai),
      target_converter: ApiConverter.get_converter(:openai),
      conversation: conversation,
      openai_body: %{"messages" => [%{"role" => "user", "content" => "hi"}]},
      mapping: %{},
      reverse_index: %{},
      pii_info: %{},
      timings: %{
        pii_duration: 0,
        source_conversion_duration: 0,
        target_conversion_duration: 0
      },
      target_headers: [],
      final_headers: [],
      target_body: %{},
      streaming: streaming,
      started: Metrics.capture_started()
    }

    stream_fun = fn chunk, conn ->
      send(test_pid, {:stream_chunk, chunk})
      {:cont, conn}
    end

    # `ProviderClient.build_handle/3` calls `StreamHandler.chunked_conn/1`
    # at construction time so the conn is already chunked when
    # `handle_chunk/2` runs. Mirror that here.
    conn = Plug.Test.conn(:get, "/") |> StreamHandler.chunked_conn()

    %Handle{
      request_context: request_context,
      conn: conn,
      stream_fun: stream_fun,
      pii_state: RestoreState.new(),
      accumulator: Accumulator.new()
    }
  end

  test "finalize/2 accepts (handle, backend_start) and emits telemetry" do
    test_pid = self()
    handler_id = "finalize-v2-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:shh_ai, :request, :stop],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry_metadata, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, conv} = Conversation.find_or_create([], %{source_provider: :openai})
    handle = build_handle(test_pid, conv)

    data_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"v2-text\"}}]}\n\n"
    done_chunk = "data: [DONE]\n\n"

    backend_start = System.monotonic_time(:microsecond)

    assert {:cont, h1, false} = StreamHandler.handle_chunk(handle, data_chunk)
    assert {:cont, h2, true} = StreamHandler.handle_chunk(h1, done_chunk)

    assert {:ok, final_id} = StreamHandler.finalize(h2, backend_start)
    assert is_binary(final_id)

    assert_receive {:telemetry_metadata, metadata}, 1_000
    assert metadata.source_provider == :openai
    # from ctx.config.name
    assert metadata.target_provider == "gpt-4"
    assert metadata.streaming == true
    assert metadata.assistant_content =~ "v2-text"
  end
end
