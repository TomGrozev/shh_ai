defmodule ShhAi.ProviderClient.SSEParserTest do
  use ExUnit.Case, async: true

  alias ShhAi.ProviderClient.SSEParser

  describe "new!/3 :data" do
    test "returns a :data event with the given payload" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hi"}}]}
      assert %SSEParser{type: :data, payload: ^payload, event_name: nil} =
               SSEParser.new!(:data, payload: payload)
    end

    test "raises when :data has no payload option" do
      assert_raise ArgumentError, fn -> SSEParser.new!(:data) end
    end

    test "raises when :data payload is not a map" do
      assert_raise ArgumentError, fn -> SSEParser.new!(:data, payload: "not a map") end
    end
  end

  describe "new!/3 :event" do
    test "returns an :event with event_name and payload" do
      payload = %{"index" => 0}
      event = SSEParser.new!(:event, event_name: "content_block_delta", payload: payload)
      assert event.type == :event
      assert event.event_name == "content_block_delta"
      assert event.payload == payload
    end

    test "raises when :event is missing event_name" do
      assert_raise ArgumentError, fn ->
        SSEParser.new!(:event, payload: %{})
      end
    end

    test "raises when :event is missing payload" do
      assert_raise ArgumentError, fn ->
        SSEParser.new!(:event, event_name: "x")
      end
    end

    test "raises when :event_name is not a string" do
      assert_raise ArgumentError, fn ->
        SSEParser.new!(:event, event_name: :not_a_string, payload: %{})
      end
    end
  end

  describe "new!/3 :done" do
    test "returns a :done event with no payload and no event_name" do
      assert %SSEParser{type: :done, event_name: nil, payload: nil} = SSEParser.new!(:done)
    end

    test "raises when :done is given extra options" do
      assert_raise ArgumentError, fn -> SSEParser.new!(:done, payload: %{}) end
    end

    test "raises when :done is given event_name" do
      assert_raise ArgumentError, fn -> SSEParser.new!(:done, event_name: "x") end
    end
  end

  describe "parse/1 data frame" do
    test "returns a :data event for a complete data: {...} frame" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Hi"}}]}
      bytes = "data: #{Jason.encode!(payload)}\n\n"

      assert [%SSEParser{type: :data, payload: ^payload, event_name: nil}] =
               SSEParser.parse(bytes)
    end

    test "decodes the data payload as a JSON map" do
      bytes = ~s(data: {"id":"chatcmpl-1","choices":[]}\n\n)

      assert [%SSEParser{type: :data, payload: %{"id" => "chatcmpl-1", "choices" => []}}] =
               SSEParser.parse(bytes)
    end
  end

  describe "parse/1 [DONE] marker" do
    test "returns a :done event for data: [DONE]" do
      bytes = "data: [DONE]\n\n"

      assert [%SSEParser{type: :done, event_name: nil, payload: nil}] =
               SSEParser.parse(bytes)
    end

    test "handles [DONE] with no leading space" do
      bytes = "data:[DONE]\n\n"

      assert [%SSEParser{type: :done, event_name: nil, payload: nil}] =
               SSEParser.parse(bytes)
    end

    test "returns :done for [DONE] in a buffer with preceding data" do
      bytes = ~s(data: {"id":"x"}\n\n) <> "data: [DONE]\n\n"

      assert [%SSEParser{type: :data, payload: %{"id" => "x"}},
              %SSEParser{type: :done, event_name: nil, payload: nil}] =
               SSEParser.parse(bytes)
    end

    test "[DONE] payload is exactly nil" do
      bytes = "data: [DONE]\n\n"
      [event] = SSEParser.parse(bytes)
      assert event.type == :done
      assert event.payload == nil
      assert event.event_name == nil
    end

    test "handles [DONE] with trailing whitespace" do
      bytes = "data: [DONE] \n\n"
      assert [%SSEParser{type: :done}] = SSEParser.parse(bytes)
    end
  end

  describe "parse/1 typed event (event: + data:)" do
    test "returns an :event with event_name and payload for event: name + data: {...}" do
      payload = %{"type" => "content_block_delta", "delta" => %{"text" => "Hello"}}
      bytes = "event: content_block_delta\ndata: #{Jason.encode!(payload)}\n\n"

      assert [%SSEParser{type: :event, event_name: "content_block_delta", payload: ^payload}] =
               SSEParser.parse(bytes)
    end

    test "decodes the data payload as a JSON map when paired with event: line" do
      payload = %{"index" => 0, "delta" => %{"text" => "Hi"}}
      bytes = "event: content_block_delta\ndata: #{Jason.encode!(payload)}\n\n"

      assert [%SSEParser{type: :event, event_name: "content_block_delta", payload: ^payload}] =
               SSEParser.parse(bytes)
    end

    test "event_name is nil and type is not :event for plain data: frame" do
      payload = %{"foo" => 1}
      bytes = "data: #{Jason.encode!(payload)}\n\n"

      [event] = SSEParser.parse(bytes)
      assert event.type == :data
      assert event.event_name == nil
    end
  end

  describe "parse/1 multiple events in one buffer" do
    test "returns a list of two :data events from two data frames in one buffer" do
      payload1 = %{"id" => "1"}
      payload2 = %{"id" => "2"}
      bytes = "data: #{Jason.encode!(payload1)}\n\ndata: #{Jason.encode!(payload2)}\n\n"

      assert [
               %SSEParser{type: :data, payload: ^payload1},
               %SSEParser{type: :data, payload: ^payload2}
             ] = SSEParser.parse(bytes)
    end

    test "returns a data event then a :done event in order" do
      payload = %{"choices" => [%{"delta" => %{"content" => "Bye"}}]}
      bytes = "data: #{Jason.encode!(payload)}\n\ndata: [DONE]\n\n"

      assert [
               %SSEParser{type: :data, payload: ^payload},
               %SSEParser{type: :done}
             ] = SSEParser.parse(bytes)
    end

    test "returns a data event then a typed event in order" do
      payload1 = %{"id" => "1"}
      payload2 = %{"type" => "content_block_delta", "delta" => %{"text" => "x"}}
      bytes = "data: #{Jason.encode!(payload1)}\n\nevent: content_block_delta\ndata: #{Jason.encode!(payload2)}\n\n"

      assert [
               %SSEParser{type: :data, payload: ^payload1},
               %SSEParser{type: :event, event_name: "content_block_delta", payload: ^payload2}
             ] = SSEParser.parse(bytes)
    end

    test "returns three events in one buffer preserving order" do
      payload1 = %{"id" => "1"}
      payload2 = %{"id" => "2"}
      payload3 = %{"id" => "3"}
      bytes =
        "data: #{Jason.encode!(payload1)}\n\n" <>
          "data: #{Jason.encode!(payload2)}\n\n" <>
          "data: #{Jason.encode!(payload3)}\n\n"

      assert [
               %SSEParser{type: :data, payload: ^payload1},
               %SSEParser{type: :data, payload: ^payload2},
               %SSEParser{type: :data, payload: ^payload3}
             ] = SSEParser.parse(bytes)
    end
  end

  describe "parse/1 partial chunks" do
    test "returns {:error, :partial} for a data: line with no terminating blank line" do
      bytes = ~s(data: {"id":"x"})

      assert {:error, :partial} = SSEParser.parse(bytes)
    end

    test "returns the complete event plus {:error, :partial} when a complete frame is followed by a partial frame" do
      payload = %{"id" => "1"}
      bytes = "data: #{Jason.encode!(payload)}\n\n" <> ~s(data: {"id":"x")

      assert {:error, :partial} = SSEParser.parse(bytes)
    end

    test "returns {:error, :partial} for a truncated JSON in a data frame" do
      bytes = ~s(data: {"id":"x)

      assert {:error, :partial} = SSEParser.parse(bytes)
    end

    test "returns {:error, :partial} for an event: line with no terminating blank line" do
      bytes = "event: content_block_delta\ndata: {\"x\":1}"

      assert {:error, :partial} = SSEParser.parse(bytes)
    end
  end

  describe "parse/1 malformed input" do
    test "returns {:error, :invalid_json} for a data: line with malformed JSON" do
      bytes = "data: {not valid json}\n\n"

      assert {:error, :invalid_json} = SSEParser.parse(bytes)
    end

    test "returns {:error, :invalid_json} for a data: line with a non-object JSON value" do
      bytes = "data: [1, 2, 3]\n\n"

      assert {:error, :invalid_json} = SSEParser.parse(bytes)
    end

    test "returns {:error, :malformed} for a frame that has only an event: line with no data:" do
      bytes = "event: ping\n\n"

      assert {:error, :malformed} = SSEParser.parse(bytes)
    end

    test "returns {:error, :malformed} for a frame that has only an event: line with empty data:" do
      bytes = "event: ping\ndata: \n\n"

      assert {:error, :malformed} = SSEParser.parse(bytes)
    end

    test "returns {:error, :malformed} for a frame that has no recognized field lines" do
      bytes = "garbage line with no colon\n\n"

      assert {:error, :malformed} = SSEParser.parse(bytes)
    end
  end

  describe "parse/1 migrated SSE-block tests" do
    # Adapted from pii_pipeline_test.exs "handles [DONE] message"
    test "[DONE] message parses as :done event" do
      bytes = "data: [DONE]\n\n"
      assert [%SSEParser{type: :done, event_name: nil, payload: nil}] = SSEParser.parse(bytes)
    end

    # Adapted from pii_pipeline_test.exs "handles chunk with event type"
    test "event: typed frame parses as :event with event_name and payload" do
      payload = %{"delta" => %{"text" => "Hello"}}
      bytes = "event: content_block_delta\ndata: #{Jason.encode!(payload)}\n\n"
      assert [%SSEParser{type: :event, event_name: "content_block_delta", payload: ^payload}] =
               SSEParser.parse(bytes)
    end

    # Adapted from pii_pipeline_test.exs "handles malformed JSON gracefully"
    test "data: frame with invalid JSON returns {:error, :invalid_json}" do
      bytes = "data: {invalid json}\n\n"
      assert {:error, :invalid_json} = SSEParser.parse(bytes)
    end

    # Adapted from pii_pipeline_test.exs "handles empty chunk"
    test "empty bytes buffer returns an empty list" do
      assert [] = SSEParser.parse("")
    end

    # Adapted from pii_pipeline_test.exs "handles chunk with no data line"
    test "event: frame with no data: returns {:error, :malformed}" do
      bytes = "event: ping\n\n"
      assert {:error, :malformed} = SSEParser.parse(bytes)
    end
  end
end
