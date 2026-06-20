defmodule ShhAi.ProviderClient.StreamTransportTest do
  use ExUnit.Case, async: false

  alias ShhAi.ApiConverter
  alias ShhAi.Conversation
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.Handle
  alias ShhAi.ProviderClient.StreamHandler.RequestMeta
  alias ShhAi.ProviderClient.StreamTransport

  setup do
    ShhAi.ConversationCase.setup_ets()
    :ok
  end

  describe "build_stream_request/4" do
    test "into: callback dispatches each chunk to StreamHandler.handle_chunk/3" do
      test_pid = self()

      stream_fun = fn chunk, conn ->
        send(test_pid, {:stream_chunk, chunk})
        {:cont, conn}
      end

      {:ok, conversation} =
        Conversation.find_or_create([], %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      spec = %{
        conn: Plug.Test.conn(:get, "/"),
        stream_fun: stream_fun,
        source_converter: ApiConverter.get_converter(:openai),
        target_converter: ApiConverter.get_converter(:openai),
        source_path: "/v1/chat/completions",
        source_provider: :openai,
        method: "POST",
        conversation: conversation,
        start_time: 1,
        started_at: 2,
        backend_start: 3,
        metrics_opts: %{
          source_provider: :openai,
          target_provider: "gpt-4",
          request_path: "/v1/chat/completions",
          method: "POST",
          streaming: true
        },
        pii_info: %{},
        pre_stream_timings: %{
          pii_duration: 0,
          source_conversion_duration: 0,
          target_conversion_duration: 0
        },
        openai_body: %{"messages" => []},
        mapping: %{},
        reverse_index: %{}
      }

      {handle, request_meta} = StreamHandler.init(spec)

      assert %Handle{} = handle
      assert %RequestMeta{} = request_meta

      request_fields = %{
        url: "http://localhost:9999/v1/chat/completions",
        method: :post,
        headers: [],
        body: %{},
        timeout: 30_000
      }

      base_request = Req.new()

      request =
        StreamTransport.build_stream_request(handle, request_meta, request_fields, base_request)

      # The new into: callback should pass the chunk through StreamHandler.handle_chunk/3
      into_fn = request.into
      resp = Req.Response.new(status: 200)
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"

      # handle_chunk/3 returns {:cont, new_handle, done?}; the closure
      # should pass this tuple shape through to Req.
      assert {:cont, {_req, _resp}} = into_fn.({:data, chunk}, {request, resp})

      # If the chunk flowed through StreamHandler.handle_chunk/3 (and not the old
      # send_chunks_to_conn/7 path), the stream_fun in the spec received it
      assert_received {:stream_chunk, sent}
      assert sent =~ "hi"
    end
  end

  describe "send_chunks_to_conn/7" do
    test "send_chunks_to_conn/7 is removed" do
      refute function_exported?(StreamTransport, :send_chunks_to_conn, 7)
    end
  end
end
