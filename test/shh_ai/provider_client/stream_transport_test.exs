defmodule ShhAi.ProviderClient.StreamTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.Callbacks, only: [on_exit: 1, setup: 1]

  alias ShhAi.ApiConverter
  alias ShhAi.Conversation
  alias ShhAi.PIIPipeline.RestoreState
  alias ShhAi.ProviderClient.RequestContext
  alias ShhAi.ProviderClient.StreamHandler
  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamHandler.Handle
  alias ShhAi.ProviderClient.StreamTransport

  setup do
    ShhAi.ConversationCase.setup_ets()
    :ok
  end

  # Helper for tests that build a fresh RequestContext (5 streaming
  # fields on the Handle wrap it).
  defp build_request_context(conversation) do
    %RequestContext{
      source_provider: :openai,
      target_provider: :openai,
      provider_instance: "openai_1",
      attempt_instance: "openai_1",
      source_path: "/v1/chat/completions",
      target_path: "/v1/chat/completions",
      method: "POST",
      config: %{name: "gpt-4", base_url: "http://localhost:9999/v1", timeout: 60_000},
      source_converter: ApiConverter.get_converter(:openai),
      target_converter: ApiConverter.get_converter(:openai),
      conversation: conversation,
      openai_body: %{"messages" => []},
      openai_headers: [],
      sanitized_body: %{},
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
      streaming: true,
      started: %{monotonic: 0, system: 0},
      sanitized_messages: []
    }
  end

  describe "build_stream_request/3" do
    test "into: callback dispatches each chunk to StreamHandler.handle_chunk/2" do
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

      handle = %Handle{
        request_context: build_request_context(conversation),
        stream_fun: stream_fun,
        conn: Plug.Test.conn(:get, "/"),
        pii_state: RestoreState.new(),
        accumulator: Accumulator.new()
      }

      backend_start = System.monotonic_time(:microsecond)

      assert %Handle{} = handle
      assert %RequestContext{} = handle.request_context
      assert is_integer(backend_start)

      request =
        StreamTransport.build_stream_request(
          handle,
          backend_start,
          Req.new(url: "http://localhost:9999/v1/chat/completions")
        )

      # The new into: callback should pass the chunk through StreamHandler.handle_chunk/2
      into_fn = request.into
      resp = Req.Response.new(status: 200)
      chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"

      # handle_chunk/2 returns {:cont, new_handle, done?}; the closure
      # should pass this tuple shape through to Req.
      assert {:cont, {_req, _resp}} = into_fn.({:data, chunk}, {request, resp})

      # If the chunk flowed through StreamHandler.handle_chunk/2, the stream_fun in the spec received it
      assert_received {:stream_chunk, sent}
      assert sent =~ "hi"
    end
  end

  describe "send_chunks_to_conn/7" do
    test "send_chunks_to_conn/7 is removed" do
      refute function_exported?(StreamTransport, :send_chunks_to_conn, 7)
    end
  end

  describe "do_stream/4 error path" do
    test "emits error telemetry, touches conversation, and never calls handle_chunk/2 on Req error" do
      test_pid = self()
      handler_id = "stream-transport-error-#{System.unique_integer([:positive])}"

      # --- 1. Telemetry: attach a handler for [:shh_ai, :request, :stop] ---
      :telemetry.attach(
        handler_id,
        [:shh_ai, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:request_stop_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # --- 2. Meck: stub Req.request/1 to return a transport error ---
      :meck.new(Req, [:passthrough])

      on_exit(fn ->
        # meck auto-unloads when its owning process exits, so the
        # test process may have already torn the mock down by the time
        # on_exit fires. Unload-arity-0 (which tolerates already-unloaded
        # modules) is the safe form.
        :meck.unload()
      end)

      :meck.expect(Req, :request, fn _request ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      # --- 3. Meck: spy on Conversation.touch/1 to assert it runs ---
      # Use [:passthrough] so other Conversation functions (if any are
      # called transitively) keep their real behavior; we just want to
      # observe touch/1.
      :meck.new(Conversation, [:passthrough])

      :meck.expect(Conversation, :touch, fn conversation_id ->
        send(test_pid, {:conversation_touched, conversation_id})
        :ok
      end)

      # --- 4. Meck: spy on StreamHandler.handle_chunk/2 to assert it
      #         is NOT called on the error path ---
      :meck.new(StreamHandler, [:passthrough])

      :meck.expect(StreamHandler, :handle_chunk, fn handle, chunk ->
        send(test_pid, {:handle_chunk_called, handle, chunk})
        # passthrough return shape so any unexpected call doesn't crash
        {:cont, handle, false}
      end)

      # --- Build a real Req.Request via build_stream_request/3 ---
      stream_fun = fn _chunk, conn -> {:cont, conn} end

      handle = %Handle{
        request_context:
          build_request_context(%{
            conversation_id: "test-conv-id",
            source_provider: :openai,
            new?: false
          }),
        stream_fun: stream_fun,
        conn: Plug.Test.conn(:get, "/"),
        pii_state: RestoreState.new(),
        accumulator: Accumulator.new()
      }

      backend_start = System.monotonic_time(:microsecond)

      request =
        StreamTransport.build_stream_request(
          handle,
          backend_start,
          Req.new(url: "http://localhost:9999/v1/chat/completions")
        )

      # --- Call do_stream/4 with the hardcoded conversation_id ---
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               StreamTransport.do_stream(request, handle, backend_start, "test-conv-id")

      # --- Assertion 1: Conversation.touch/1 was called with "test-conv-id" ---
      assert_received {:conversation_touched, "test-conv-id"}

      # --- Assertion 2: error telemetry was emitted with the right fields ---
      assert_receive {:request_stop_telemetry, metadata}, 1_000

      assert metadata.source_provider == :openai
      assert metadata.target_provider == "gpt-4"
      assert metadata.streaming == true
      assert metadata.conversation_id == "test-conv-id"
      assert is_map(metadata.error)
      assert metadata.error.type == :stream_error
      assert is_binary(metadata.error.message)

      # --- Assertion 3: StreamHandler.handle_chunk/2 was NEVER called ---
      handle_chunk_calls =
        StreamHandler
        |> :meck.history()
        |> Enum.filter(fn {_pid, {_mod, fun, _args}, _result} -> fun == :handle_chunk end)

      assert handle_chunk_calls == [],
             "StreamHandler.handle_chunk/2 must not be called on the Req error path, " <>
               "but it was invoked #{length(handle_chunk_calls)} time(s): #{inspect(handle_chunk_calls)}"
    end

    test "tags the error with the first-byte boundary when chunks were already delivered" do
      test_pid = self()

      :meck.new(Req, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(Req, :request, fn request ->
        # One chunk flows through the into: callback, then the request
        # fails mid-stream (issue #72: the retry boundary is the first byte).
        request.into.(
          {:data, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"},
          {request, Req.Response.new(status: 200)}
        )

        {:error, %Req.TransportError{reason: :closed}}
      end)

      :meck.new(StreamHandler, [:passthrough])

      # A real chunk mutates the handle (accumulates the delta), so the
      # dictionary handle diverges from the initial one and the failure is
      # recognised as mid-stream. The mock mimics that mutation.
      :meck.expect(StreamHandler, :handle_chunk, fn handle, chunk ->
        send(test_pid, {:handle_chunk_called})

        changed = %{
          handle
          | accumulator: %{
              handle.accumulator
              | assistant_content_chunks: handle.accumulator.assistant_content_chunks ++ [chunk]
            }
        }

        {:cont, changed, false}
      end)

      stream_fun = fn _chunk, conn -> {:cont, conn} end

      handle = %Handle{
        request_context:
          build_request_context(%{
            conversation_id: "test-conv-id-midstream",
            source_provider: :openai,
            new?: false
          }),
        stream_fun: stream_fun,
        conn: Plug.Test.conn(:get, "/"),
        pii_state: RestoreState.new(),
        accumulator: Accumulator.new()
      }

      backend_start = System.monotonic_time(:microsecond)

      request =
        StreamTransport.build_stream_request(
          handle,
          backend_start,
          Req.new(url: "http://localhost:9999/v1/chat/completions")
        )

      # A chunk was delivered to the handler, so the error must be tagged
      # `{:stream_failed_after_first_byte, _}` — the caller's retry boundary.
      assert {:error, {:stream_failed_after_first_byte, %Req.TransportError{reason: :closed}}} =
               StreamTransport.do_stream(request, handle, backend_start, "test-conv-id-midstream")

      assert_received {:handle_chunk_called}
    end

    test "an error before any chunk is left untagged so the caller may retry" do
      :meck.new(Req, [:passthrough])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(Req, :request, fn _request ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      stream_fun = fn _chunk, conn -> {:cont, conn} end

      handle = %Handle{
        request_context:
          build_request_context(%{
            conversation_id: "test-conv-id-prestream",
            source_provider: :openai,
            new?: false
          }),
        stream_fun: stream_fun,
        conn: Plug.Test.conn(:get, "/"),
        pii_state: RestoreState.new(),
        accumulator: Accumulator.new()
      }

      backend_start = System.monotonic_time(:microsecond)

      request =
        StreamTransport.build_stream_request(
          handle,
          backend_start,
          Req.new(url: "http://localhost:9999/v1/chat/completions")
        )

      # No chunk was delivered, so the raw reason passes through and the
      # caller decides whether the failure is retryable.
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               StreamTransport.do_stream(request, handle, backend_start, "test-conv-id-prestream")
    end
  end
end
