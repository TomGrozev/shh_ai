defmodule ShhAi.Proxy.SessionStore.ETSTest do
  use ExUnit.Case, async: false

  alias ShhAi.Proxy.Config
  alias ShhAi.Proxy.SessionStore
  alias ShhAi.Proxy.SessionStore.ETS

  setup do
    # Ensure ETS backend is configured for tests
    System.delete_env("SESSION_STORE_BACKEND")
    Config.load()

    # Initialize ETS tables
    ETS.init()
    :ok
  end

  describe "create/0" do
    test "creates a new session with unique ID" do
      {:ok, session_id} = SessionStore.create()

      assert is_binary(session_id)
      assert String.starts_with?(session_id, "sess_")
    end

    test "creates sessions with unique IDs" do
      {:ok, id1} = SessionStore.create()
      {:ok, id2} = SessionStore.create()

      refute id1 == id2
    end
  end

  describe "put/2 and get/2" do
    test "stores and retrieves mapping" do
      {:ok, session_id} = SessionStore.create()
      mapping = %{"PERSON_1" => "John Doe", "LOCATION_1" => "New York"}

      :ok = SessionStore.put(session_id, mapping)
      {:ok, retrieved} = SessionStore.get(session_id)

      assert retrieved == mapping
    end

    test "updates existing mapping" do
      {:ok, session_id} = SessionStore.create()
      mapping1 = %{"PERSON_1" => "John"}
      mapping2 = %{"PERSON_1" => "Jane", "LOCATION_1" => "Paris"}

      :ok = SessionStore.put(session_id, mapping1)
      :ok = SessionStore.put(session_id, mapping2)
      {:ok, retrieved} = SessionStore.get(session_id)

      assert retrieved == mapping2
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      {:ok, session_id} = SessionStore.create()
      :ok = SessionStore.put(session_id, %{"key" => "value"})

      :ok = SessionStore.delete(session_id)

      assert {:error, :not_found} = SessionStore.get(session_id)
    end
  end

  describe "TTL expiration" do
    test "expired sessions return not_found" do
      # Create session
      {:ok, session_id} = SessionStore.create()
      :ok = SessionStore.put(session_id, %{"key" => "value"})

      # Verify it exists first
      assert {:ok, _} = SessionStore.get(session_id)

      # Manually expire the session by setting its expiry to a past time
      # System.monotonic_time can be negative, so we use a value guaranteed to be in the past
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {session_id, %{"key" => "value"}, past_time})

      # Should return not_found for expired session
      assert {:error, :not_found} = SessionStore.get(session_id)
    end
  end

  describe "cleanup_expired/0" do
    test "removes expired sessions" do
      # Create sessions
      {:ok, active_id} = SessionStore.create()
      {:ok, expired_id} = SessionStore.create()

      :ok = SessionStore.put(active_id, %{"active" => "true"})
      :ok = SessionStore.put(expired_id, %{"expired" => "true"})

      # Verify both exist
      assert {:ok, _} = SessionStore.get(active_id)
      assert {:ok, _} = SessionStore.get(expired_id)

      # Expire one session by setting its expiry to a past time
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {expired_id, %{"expired" => "true"}, past_time})

      # Cleanup
      count = ETS.cleanup_expired()

      # At least one session should be cleaned up (the expired one)
      assert count >= 1

      # Active session should still exist
      assert {:ok, _} = SessionStore.get(active_id)

      # Expired session should be gone
      assert {:error, :not_found} = SessionStore.get(expired_id)
    end
  end

  describe "backend/0" do
    test "returns ETS backend when configured" do
      System.delete_env("SESSION_STORE_BACKEND")
      Config.load()

      assert SessionStore.backend() == ShhAi.Proxy.SessionStore.ETS
    end
  end
end
