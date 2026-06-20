defmodule ShhAi.ProviderClient.StreamHandlerTest do
  use ExUnit.Case, async: false

  alias ShhAi.ApiConverter
  alias ShhAi.Conversation
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle
  alias ShhAi.ProviderClient.StreamHandler.RequestMeta

  setup do
    ShhAi.ConversationCase.setup_ets()

    {:ok, _conversation} =
      Conversation.find_or_create([], %{
        source_provider: :openai,
        provider_conversation_id: nil
      })

    :ok
  end

  defp build_spec(test_pid) do
    stream_fun = fn chunk, conn ->
      send(test_pid, {:stream_chunk, chunk})
      {:cont, conn}
    end

    {:ok, conversation} =
      Conversation.find_or_create([], %{
        source_provider: :openai,
        provider_conversation_id: nil
      })

    %{
      conn: Plug.Test.conn(:get, "/"),
      stream_fun: stream_fun,
      source_converter: ApiConverter.get_converter(:openai),
      target_converter: ApiConverter.get_converter(:openai),
      source_path: "/v1/chat/completions",
      source_provider: :openai,
      method: "POST",
      conversation: conversation,
      start_time: System.monotonic_time(:microsecond),
      started_at: System.system_time(:microsecond),
      backend_start: System.monotonic_time(:microsecond),
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
  end

  describe "init/1 + handle_chunk/3 (tracer bullet)" do
    test "init returns {handle, request_meta}, first chunk sends a converted chunk through stream_fun" do
      {handle, request_meta} = StreamHandler.init(build_spec(self()))
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"

      assert {:cont, new_handle, false} = StreamHandler.handle_chunk(handle, chunk, nil)
      assert is_struct(new_handle)

      assert_received {:stream_chunk, sent_chunk}
      assert sent_chunk =~ "hello"
      assert %RequestMeta{} = request_meta
    end
  end

  describe "handle_chunk/3 multi-chunk" do
    test "threads accumulator and pii_state across N=3 chunks" do
      test_pid = self()
      {handle, _request_meta} = StreamHandler.init(build_spec(test_pid))

      chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n"
      chunk2 = "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n"
      chunk3 = "data: {\"choices\":[{\"delta\":{\"content\":\"c\"}}]}\n\n"

      assert {:cont, h1, false} = StreamHandler.handle_chunk(handle, chunk1, nil)
      assert %Accumulator{} = h1.accumulator
      # Prepended (newest first) — so after first chunk, ["a"]
      assert h1.accumulator.assistant_content_chunks == ["a"]
      assert h1.accumulator.restore_duration > 0
      assert is_binary(h1.pii_state.buffer)

      assert {:cont, h2, false} = StreamHandler.handle_chunk(h1, chunk2, nil)
      assert h2.accumulator.assistant_content_chunks == ["b", "a"]
      assert h2.accumulator.restore_duration > h1.accumulator.restore_duration
      assert is_binary(h2.pii_state.buffer)

      assert {:cont, h3, false} = StreamHandler.handle_chunk(h2, chunk3, nil)
      assert h3.accumulator.assistant_content_chunks == ["c", "b", "a"]
      assert h3.accumulator.restore_duration > h2.accumulator.restore_duration
      assert is_binary(h3.pii_state.buffer)

      # Mailbox should have 3 chunks in order
      chunks = for i <- 1..3, do: receive_for(i)
      assert Enum.all?(chunks, &is_binary/1)
      # All three letter contents should be present, in order
      combined = Enum.join(chunks, "")
      assert combined =~ ~s("content":"a")
      assert combined =~ ~s("content":"b")
      assert combined =~ ~s("content":"c")
      a_idx = :binary.match(combined, ~s("content":"a")) |> elem(0)
      b_idx = :binary.match(combined, ~s("content":"b")) |> elem(0)
      c_idx = :binary.match(combined, ~s("content":"c")) |> elem(0)
      assert a_idx < b_idx and b_idx < c_idx
    end
  end

  describe "handle_chunk/3 finalization" do
    test "emits Metrics.emit_stream_stop telemetry after [DONE]" do
      test_pid = self()
      handler_id = "stream-handler-finalize-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:stream_stop_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {handle, request_meta} = StreamHandler.init(build_spec(test_pid))
      data_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"done-text\"}}]}\n\n"
      done_chunk = "data: [DONE]\n\n"

      assert {:cont, h1, false} = StreamHandler.handle_chunk(handle, data_chunk, nil)
      assert {:cont, h2, true} = StreamHandler.handle_chunk(h1, done_chunk, nil)

      # The done? signal tells the closure to call finalize. We do it
      # manually here (mirrors the closure in StreamTransport).
      {:ok, _final_handle, _final_id} = StreamHandler.finalize(h2, request_meta)

      assert_receive {:stream_stop_telemetry, metadata}, 1_000
      assert metadata.source_provider == :openai
      assert metadata.target_provider == "gpt-4"
      assert metadata.streaming == true
      assert metadata.status == 200
      assert metadata.assistant_content =~ "done-text"
    end
  end

  describe "Handle struct shape" do
    test "init/1 returns a Handle with exactly the per-request + per-chunk fields (no per-finalization leakage)" do
      {handle, _request_meta} = StreamHandler.init(build_spec(self()))

      assert %Handle{} = handle

      # All 13 enforced keys are present.
      expected_keys = [
        :source_converter,
        :target_converter,
        :source_path,
        :source_provider,
        :method,
        :conversation,
        :openai_body,
        :mapping,
        :reverse_index,
        :stream_fun,
        :conn,
        :pii_state,
        :accumulator
      ]

      for key <- expected_keys do
        assert Map.has_key?(handle, key), "Handle missing field #{inspect(key)}"
      end

      # The struct's @enforce_keys is exactly the expected 13 fields.
      actual_keys = Handle.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))
      assert Enum.sort(actual_keys) == Enum.sort(expected_keys)
    end

    test "Handle has no per-finalization fields" do
      {handle, _request_meta} = StreamHandler.init(build_spec(self()))

      refute Map.has_key?(handle, :start_time)
      refute Map.has_key?(handle, :started_at)
      refute Map.has_key?(handle, :backend_start)
      refute Map.has_key?(handle, :metrics_opts)
      refute Map.has_key?(handle, :pii_info)
      refute Map.has_key?(handle, :pre_stream_timings)
    end

    test "RequestMeta has no conversation_id" do
      {_handle, request_meta} = StreamHandler.init(build_spec(self()))

      refute Map.has_key?(request_meta, :conversation_id)
    end
  end

  describe "old code-path removal" do
    alias ShhAi.ProviderClient
    alias ShhAi.ProviderClient.StreamTransport

    test "ProviderClient.handle_stream_chunk/5 is removed" do
      refute function_exported?(ProviderClient, :handle_stream_chunk, 5)
    end

    test "StreamTransport.send_chunks_to_conn/7 is removed" do
      refute function_exported?(StreamTransport, :send_chunks_to_conn, 7)
    end

    test "ProviderClient.update_accumulator/4 is removed" do
      refute function_exported?(ProviderClient, :update_accumulator, 4)
    end
  end

  describe "acceptance: no Req.Response.put_private leakage on streaming path" do
    @pii_state_regex ~r/Req\.Response\.put_private\([^,]+,\s*:pii_state/
    @metrics_context_regex ~r/Req\.Response\.put_private\([^,]+,\s*:metrics_context/

    test "no lib/ file sets :pii_state via Req.Response.put_private" do
      for file <- Path.wildcard("lib/**/*.ex") do
        content = File.read!(file)

        refute content =~ @pii_state_regex,
               "#{file} still sets :pii_state via Req.Response.put_private"
      end
    end

    test "no lib/ file sets :metrics_context via Req.Response.put_private" do
      for file <- Path.wildcard("lib/**/*.ex") do
        content = File.read!(file)

        refute content =~ @metrics_context_regex,
               "#{file} still sets :metrics_context via Req.Response.put_private"
      end
    end
  end

  defp receive_for(i) do
    receive do
      {:stream_chunk, c} -> c
    after
      1_000 -> flunk("expected #{i} chunks, mailbox is empty")
    end
  end
end
