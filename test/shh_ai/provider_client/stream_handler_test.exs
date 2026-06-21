defmodule ShhAi.ProviderClient.StreamHandlerTest do
  use ExUnit.Case, async: false

  alias ShhAi.ApiConverter
  alias ShhAi.Conversation
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle

  setup do
    ShhAi.ConversationCase.setup_ets()

    {:ok, _conversation} =
      Conversation.find_or_create([], %{
        source_provider: :openai,
        provider_conversation_id: nil
      })

    :ok
  end

  # Constructs a fresh `{Handle, backend_start}` pair for tests.
  # Mirrors the production construction in
  # `ProviderClient.perform_stream/3` — the handle nests a
  # `%RequestContext{}` (per-request static state shared with the
  # non-streaming request path) plus 4 streaming-only fields, and
  # `backend_start` is a monotonic integer captured immediately before
  # `Req.request/1` (here, before `finalize/2`). See
  # `finalize_test.exs` for the new contract.
  defp build_handle_meta(test_pid, conversation \\ nil, openai_body \\ %{"messages" => []}) do
    stream_fun = fn chunk, conn ->
      send(test_pid, {:stream_chunk, chunk})
      {:cont, conn}
    end

    conv =
      conversation ||
        elem(
          Conversation.find_or_create([], %{
            source_provider: :openai,
            provider_conversation_id: nil
          }),
          1
        )

    request_context = %RequestContext{
      source_provider: :openai,
      target_provider: :openai,
      source_path: "/v1/chat/completions",
      target_path: "/v1/chat/completions",
      method: "POST",
      config: %{name: "gpt-4", base_url: "http://localhost:9999/v1", timeout: 60_000},
      source_converter: ApiConverter.get_converter(:openai),
      target_converter: ApiConverter.get_converter(:openai),
      conversation: conv,
      openai_body: openai_body,
      mapping: %{},
      reverse_index: %{},
      pii_info: %{},
      timings: %{
        pii_duration: 0,
        source_conversion_duration: 0,
        target_conversion_duration: 0
      },
      target_headers: [],
      target_body: %{},
      streaming: true,
      started: %{monotonic: 0, system: 0}
    }

    handle = %Handle{
      request_context: request_context,
      conn: Plug.Test.conn(:get, "/"),
      stream_fun: stream_fun,
      pii_state: %{buffer: ""},
      accumulator: Accumulator.new()
    }

    backend_start = System.monotonic_time(:microsecond)

    {handle, backend_start}
  end

  describe "handle_chunk/3 (tracer bullet)" do
    test "first chunk sends a converted chunk through stream_fun" do
      {handle, backend_start} = build_handle_meta(self())
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"

      assert {:cont, new_handle, false} = StreamHandler.handle_chunk(handle, chunk, nil)
      assert is_struct(new_handle)

      assert_received {:stream_chunk, sent_chunk}
      assert sent_chunk =~ "hello"
      assert is_integer(backend_start)
    end
  end

  describe "handle_chunk/3 multi-chunk" do
    test "threads accumulator and pii_state across N=3 chunks" do
      test_pid = self()
      {handle, _backend_start} = build_handle_meta(test_pid)

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

  describe "finalize/2 Turn 1 (new conversation)" do
    test "persists the conversation and emits telemetry for a fresh (new?: true) conversation" do
      test_pid = self()
      handler_id = "turn1-finalize-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:turn1_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Build a handle with a new (in-memory, not yet persisted) conversation.
      # `find_or_create` with an empty message list returns a conversation
      # with new?: true and a freshly generated UUID.
      {:ok, fresh_conversation} =
        Conversation.find_or_create([], %{
          source_provider: :openai,
          provider_conversation_id: nil
        })

      assert fresh_conversation.new?

      {handle, backend_start} =
        build_handle_meta(
          test_pid,
          fresh_conversation,
          %{"messages" => [%{"role" => "user", "content" => "hi"}]}
        )

      data_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"turn1-text\"}}]}\n\n"
      done_chunk = "data: [DONE]\n\n"

      assert {:cont, h1, false} = StreamHandler.handle_chunk(handle, data_chunk, nil)
      assert {:cont, h2, true} = StreamHandler.handle_chunk(h1, done_chunk, nil)
      assert {:ok, _final_handle, final_id} = StreamHandler.finalize(h2, backend_start)

      # Turn 1: persist_turn_1 derives a deterministic UUID v5 from the
      # first-exchange fingerprint. The returned id is a stable string,
      # not the original `new?` conversation id.
      assert is_binary(final_id)
      assert final_id != fresh_conversation.conversation_id

      # The conversation is now persisted in the store.
      assert {:ok, _stored} = Conversation.Store.get_conversation(final_id)

      assert_receive {:turn1_telemetry, metadata}, 1_000
      assert metadata.assistant_content =~ "turn1-text"
      assert metadata.conversation_id == final_id
    end
  end

  describe "handle_chunk/3 error and halt paths" do
    test "returns {:cont, _, false} when the converter signals an error (invalid format)" do
      {handle, _backend_start} = build_handle_meta(self())

      # A garbage chunk that the converter cannot parse (not a complete SSE
      # frame, no recognizable fields).
      assert {:cont, new_handle, false} =
               StreamHandler.handle_chunk(handle, "this is not sse\n", nil)

      assert %Handle{} = new_handle
    end

    test "returns {:halt, _, _} when the stream_fun signals :halt" do
      test_pid = self()

      request_context = %RequestContext{
        source_provider: :openai,
        target_provider: :openai,
        source_path: "/v1/chat/completions",
        target_path: "/v1/chat/completions",
        method: "POST",
        config: %{name: "gpt-4", base_url: "http://localhost:9999/v1", timeout: 60_000},
        source_converter: ApiConverter.get_converter(:openai),
        target_converter: ApiConverter.get_converter(:openai),
        conversation:
          elem(
            Conversation.find_or_create([], %{
              source_provider: :openai,
              provider_conversation_id: nil
            }),
            1
          ),
        openai_body: %{"messages" => []},
        mapping: %{},
        reverse_index: %{},
        pii_info: %{},
        timings: %{
          pii_duration: 0,
          source_conversion_duration: 0,
          target_conversion_duration: 0
        },
        target_headers: [],
        target_body: %{},
        streaming: true,
        started: %{monotonic: 0, system: 0}
      }

      halt_handle = %Handle{
        request_context: request_context,
        stream_fun: fn chunk, _conn ->
          send(test_pid, {:stream_chunk, chunk})
          :halt
        end,
        conn: Plug.Test.conn(:get, "/"),
        pii_state: %{buffer: ""},
        accumulator: Accumulator.new()
      }

      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"

      assert {:halt, _new_handle, false} = StreamHandler.handle_chunk(halt_handle, chunk, nil)
      assert_received {:stream_chunk, _}
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

      {handle, backend_start} = build_handle_meta(test_pid)
      data_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"done-text\"}}]}\n\n"
      done_chunk = "data: [DONE]\n\n"

      assert {:cont, h1, false} = StreamHandler.handle_chunk(handle, data_chunk, nil)
      assert {:cont, h2, true} = StreamHandler.handle_chunk(h1, done_chunk, nil)

      # The done? signal tells the closure to call finalize. We do it
      # manually here (mirrors the closure in StreamTransport).
      {:ok, _final_handle, _final_id} = StreamHandler.finalize(h2, backend_start)

      assert_receive {:stream_stop_telemetry, metadata}, 1_000
      assert metadata.source_provider == :openai
      assert metadata.target_provider == "gpt-4"
      assert metadata.streaming == true
      assert metadata.status == 200
      assert metadata.assistant_content =~ "done-text"
    end
  end

  describe "Handle struct shape" do
    test "Handle has exactly the 5 streaming fields (RequestContext + 4 streaming-only)" do
      {handle, _backend_start} = build_handle_meta(self())

      assert %Handle{} = handle

      # 5 enforced keys: request_context nests the per-request static
      # state; the remaining 4 are streaming-only.
      expected_keys = [
        :request_context,
        :conn,
        :stream_fun,
        :pii_state,
        :accumulator
      ]

      for key <- expected_keys do
        assert Map.has_key?(handle, key), "Handle missing field #{inspect(key)}"
      end

      # The struct's @enforce_keys is exactly the expected 5 fields.
      actual_keys = Handle.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))
      assert Enum.sort(actual_keys) == Enum.sort(expected_keys)
    end

    test "Handle.request_context holds the per-request static state" do
      {handle, _backend_start} = build_handle_meta(self())
      ctx = handle.request_context

      assert %RequestContext{} = ctx
      assert ctx.source_provider == :openai
      assert ctx.method == "POST"
      assert ctx.source_path == "/v1/chat/completions"
    end

    test "Handle has no per-finalization fields" do
      {handle, _backend_start} = build_handle_meta(self())

      refute Map.has_key?(handle, :start_time)
      refute Map.has_key?(handle, :started_at)
      refute Map.has_key?(handle, :backend_start)
      refute Map.has_key?(handle, :metrics_opts)
      refute Map.has_key?(handle, :pii_info)
      refute Map.has_key?(handle, :pre_stream_timings)
    end

    test "RequestContext has no per-finalization fields" do
      {handle, _backend_start} = build_handle_meta(self())
      ctx = handle.request_context

      refute Map.has_key?(ctx, :start_time)
      refute Map.has_key?(ctx, :started_at)
      refute Map.has_key?(ctx, :backend_start)
      refute Map.has_key?(ctx, :metrics_opts)
    end

    test "build_handle_meta/3 returns backend_start as a monotonic integer" do
      # The per-finalization value returned alongside the handle is a
      # bare monotonic integer (the instant `Req.request/1` is about
      # to be called).
      {_handle, backend_start} = build_handle_meta(self())

      assert is_integer(backend_start)

      after_call = System.monotonic_time(:microsecond)
      assert backend_start <= after_call
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

  describe "hot path: SSEParser.parse/1 called exactly twice per chunk" do
    alias ShhAi.ProviderClient.SSEParser

    # Regression guard for issue #21 A1.
    #
    # Before the fix: 4 SSEParser.parse calls per chunk on the
    # OpenAI->OpenAI path (target_converter, restore_stream_chunk,
    # extract_content_from_openai_chunks, source_converter).
    #
    # After the fix: 2 calls — one for the target-side events extraction
    # (`to_openai_stream_events/2`) and one for the source-side wire
    # conversion (`from_openai_stream_chunk/2`). The middle two parses
    # (restore + content-extraction) now consume the typed events instead
    # of re-parsing the wire format.
    test "SSEParser.parse/1 is invoked exactly twice per chunk (regression guard for #21 A1)" do
      test_pid = self()

      :meck.new(SSEParser, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      # Wrap parse/1 to count invocations and forward to the real impl.
      :meck.expect(SSEParser, :parse, fn bytes ->
        send(test_pid, {:sse_parse_called, byte_size(bytes)})
        :meck.passthrough([bytes])
      end)

      {handle, _backend_start} = build_handle_meta(test_pid)
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"

      assert {:cont, _new_handle, false} = StreamHandler.handle_chunk(handle, chunk, nil)

      assert_received {:sse_parse_called, _}
      assert_received {:sse_parse_called, _}
      refute_received {:sse_parse_called, _}
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
