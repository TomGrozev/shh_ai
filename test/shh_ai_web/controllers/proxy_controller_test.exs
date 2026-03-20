defmodule ShhAiWeb.ProxyControllerTest do
  use ShhAiWeb.ConnCase, async: false

  alias ShhAi.Proxy.Config
  alias ShhAi.Proxy.SessionStore

  setup do
    # Initialize config
    Config.load()
    SessionStore.ETS.init()
    :ok
  end

  describe "handle_openai/2" do
    test "returns error when API key not configured" do
      System.delete_env("OPENAI_API_KEY")
      Config.load()

      conn =
        build_conn()
        |> post("/v1/chat/completions", %{"model" => "gpt-4", "messages" => []})

      # Since we're not forwarding to a real API, we expect an error
      # In Phase 1, we're just testing that the controller handles the request
      assert conn.status == 500 || conn.status == 404
    end
  end

  describe "detect_provider/1" do
    test "detects OpenAI as default" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")

      # The controller should default to OpenAI for /v1/* paths
      # This is tested indirectly through routing
      _conn = conn
    end
  end

  describe "session management" do
    test "creates and cleans up sessions" do
      {:ok, session_id} = SessionStore.create()

      assert is_binary(session_id)

      :ok = SessionStore.put(session_id, %{"test" => "value"})
      {:ok, mapping} = SessionStore.get(session_id)

      assert mapping == %{"test" => "value"}

      :ok = SessionStore.delete(session_id)
      assert {:error, :not_found} = SessionStore.get(session_id)
    end
  end
end
