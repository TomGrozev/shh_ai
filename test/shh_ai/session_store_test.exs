defmodule ShhAi.SessionStoreTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.SessionStore
  alias ShhAi.SessionStore.ETS

  setup do
    # Configure ETS backend
    System.delete_env("SESSION_STORE_BACKEND")
    Config.load()

    # Initialize ETS tables
    ETS.init()
    :ok
  end

  describe "backend/0" do
    test "returns ETS backend when configured" do
      System.delete_env("SESSION_STORE_BACKEND")
      Config.load()

      backend = SessionStore.backend()
      assert backend == ShhAi.SessionStore.ETS
    end
  end

  describe "create/0" do
    test "creates a new session" do
      {:ok, session_id} = SessionStore.create()

      assert is_binary(session_id)
      assert String.starts_with?(session_id, "sess_")
    end

    test "creates unique session IDs" do
      {:ok, id1} = SessionStore.create()
      {:ok, id2} = SessionStore.create()

      refute id1 == id2
    end
  end

  describe "put/2 and get/1" do
    test "stores and retrieves mapping" do
      {:ok, session_id} = SessionStore.create()
      mapping = %{"key1" => "value1", "key2" => "value2"}

      :ok = SessionStore.put(session_id, mapping)
      {:ok, retrieved} = SessionStore.get(session_id)

      assert retrieved == mapping
    end

    test "updates existing mapping" do
      {:ok, session_id} = SessionStore.create()
      mapping1 = %{"key1" => "value1"}
      mapping2 = %{"key1" => "updated", "key2" => "value2"}

      :ok = SessionStore.put(session_id, mapping1)
      :ok = SessionStore.put(session_id, mapping2)
      {:ok, retrieved} = SessionStore.get(session_id)

      assert retrieved == mapping2
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} == SessionStore.get("non_existent")
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      {:ok, session_id} = SessionStore.create()
      :ok = SessionStore.put(session_id, %{"key" => "value"})

      :ok = SessionStore.delete(session_id)

      assert {:error, :not_found} == SessionStore.get(session_id)
    end
  end

  describe "cleanup/0" do
    test "returns count of cleaned up sessions for ETS backend" do
      # Create some sessions
      {:ok, active_id} = SessionStore.create()
      {:ok, expired_id} = SessionStore.create()

      :ok = SessionStore.put(active_id, %{"active" => "true"})
      :ok = SessionStore.put(expired_id, %{"expired" => "true"})

      # Manually expire one session
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {expired_id, %{"expired" => "true"}, past_time})

      # Trigger cleanup
      count = SessionStore.cleanup()

      # Should have cleaned up at least one session
      assert count >= 1

      # Active session should still exist
      assert {:ok, _} = SessionStore.get(active_id)

      # Expired session should be gone
      assert {:error, :not_found} = SessionStore.get(expired_id)
    end
  end

  describe "GenServer callbacks" do
    test "init/1 initializes with ETS backend" do
      System.delete_env("SESSION_STORE_BACKEND")
      Config.load()

      assert {:ok, %{backend: ShhAi.SessionStore.ETS}} = SessionStore.init([])
    end

    test "handle_call :backend returns current backend" do
      {:ok, state} = SessionStore.init([])
      {:reply, backend, ^state} = SessionStore.handle_call(:backend, nil, state)

      assert backend == ShhAi.SessionStore.ETS
    end

    test "handle_call :cleanup returns cleanup count" do
      {:ok, state} = SessionStore.init([])

      # Create an expired session manually
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {"test_expired", %{}, past_time})

      {:reply, count, ^state} = SessionStore.handle_call(:cleanup, nil, state)

      assert is_integer(count)
      assert count >= 0
    end

    test "handle_info :cleanup schedules next cleanup" do
      {:ok, state} = SessionStore.init([])

      # This should schedule the next cleanup and return noreply
      {:noreply, ^state} = SessionStore.handle_info(:cleanup, state)
    end
  end

  describe "error handling" do
    test "ETS backend handles non-existent session gracefully" do
      assert {:error, :not_found} = ETS.get("non_existent_session_id")
    end

    test "delete on non-existent session succeeds" do
      assert :ok = ETS.delete("non_existent_session_id")
    end
  end
end
