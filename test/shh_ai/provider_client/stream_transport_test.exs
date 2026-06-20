defmodule ShhAi.ProviderClient.StreamTransportTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.StreamHandler.Accumulator
  alias ShhAi.ProviderClient.StreamTransport

  describe "build_stream_request/3" do
    test "seeds :request_meta on resp.private via into: callback" do
      alias ShhAi.ProviderClient.StreamContext
      alias ShhAi.ProviderClient.StreamHandler.RequestMeta

      ctx = %StreamContext{
        conn: nil,
        stream_fun: fn _chunk, conn -> {:cont, conn} end,
        source_provider: :openai,
        source_path: "/v1/chat/completions",
        method: "POST",
        conversation: %{conversation_id: "conv-stream-meta"},
        start_time: 42,
        started_at: 99,
        backend_start: 55,
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
        openai_body: %{},
        source_converter: nil,
        target_converter: nil,
        mapping: %{},
        reverse_index: %{}
      }

      request_fields = %{
        url: "http://localhost:9999/v1/chat/completions",
        method: :post,
        headers: [],
        body: %{},
        timeout: 30_000
      }

      base_request = Req.new()
      request = StreamTransport.build_stream_request(ctx, request_fields, base_request)

      # Extract the :into callback and invoke it with empty data
      into_fn = request.into
      resp = Req.Response.new(status: 200)

      {:cont, {_req, new_resp}} = into_fn.({:data, ""}, {request, resp})

      meta = Req.Response.get_private(new_resp, :request_meta)
      assert %RequestMeta{} = meta
      assert meta.start_time == 42
      assert meta.conversation_id == "conv-stream-meta"
      assert meta.metrics_opts == ctx.metrics_opts
    end
  end

  describe "send_chunks_to_conn/7" do
    test "accepts %Accumulator{} as 6th parameter and does NOT stash :metrics_context on resp" do
      acc = Accumulator.new()
      req = Req.new()
      resp = Req.Response.new(status: 200)
      conn = Plug.Test.conn(:get, "/")
      stream_fun = fn _chunk, conn -> {:cont, conn} end

      {_status, {_req, new_resp}} =
        StreamTransport.send_chunks_to_conn(
          ["hello"],
          conn,
          req,
          resp,
          %{},
          acc,
          stream_fun
        )

      assert Req.Response.get_private(new_resp, :metrics_context) == nil,
             "send_chunks_to_conn must not stash :metrics_context on resp.private"
    end

    test "still stashes :req_conn and :pii_state on resp.private" do
      acc = Accumulator.new()
      req = Req.new()
      resp = Req.Response.new(status: 200)
      conn = Plug.Test.conn(:get, "/")
      stream_fun = fn _chunk, conn -> {:cont, conn} end

      {_status, {_req, new_resp}} =
        StreamTransport.send_chunks_to_conn(
          ["hello"],
          conn,
          req,
          resp,
          %{some: :pii_state},
          acc,
          stream_fun
        )

      assert Req.Response.get_private(new_resp, :req_conn) != nil
      assert Req.Response.get_private(new_resp, :pii_state) == %{some: :pii_state}
    end
  end
end
