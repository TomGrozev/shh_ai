defmodule ShhAi.SessionStore.ETSTest do
  use ExUnit.Case, async: false

  alias ShhAi.Config
  alias ShhAi.SessionStore.ETS

  setup do
    # Ensure ETS backend is configured for tests
    System.delete_env("SESSION_STORE_BACKEND")
    Config.load()

    # Initialize ETS tables
    ETS.init()
    :ok
  end

  describe "init/0" do
    test "initializes ETS tables successfully" do
      # Tables should already exist from setup
      assert :ets.info(:proxy_sessions) != :undefined
      assert :ets.info(:proxy_session_counter) != :undefined
    end

    test "can be called multiple times without error" do
      assert ETS.init() == :ok
      assert ETS.init() == :ok
    end
  end

  describe "create/0" do
    test "creates a new session with unique ID" do
      {:ok, session_id} = ETS.create()

      assert is_binary(session_id)
      assert String.starts_with?(session_id, "sess_")
    end

    test "creates sessions with unique IDs" do
      {:ok, id1} = ETS.create()
      {:ok, id2} = ETS.create()

      refute id1 == id2
    end
  end

  describe "put/2 and get/1" do
    test "stores and retrieves mapping" do
      {:ok, session_id} = ETS.create()
      mapping = %{"PERSON_1" => "John Doe", "LOCATION_1" => "New York"}

      :ok = ETS.put(session_id, mapping)
      {:ok, retrieved} = ETS.get(session_id)

      assert retrieved == mapping
    end

    test "updates existing mapping" do
      {:ok, session_id} = ETS.create()
      mapping1 = %{"PERSON_1" => "John"}
      mapping2 = %{"PERSON_1" => "Jane", "LOCATION_1" => "Paris"}

      :ok = ETS.put(session_id, mapping1)
      :ok = ETS.put(session_id, mapping2)
      {:ok, retrieved} = ETS.get(session_id)

      assert retrieved == mapping2
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} == ETS.get("non_existent_session")
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      {:ok, session_id} = ETS.create()
      :ok = ETS.put(session_id, %{"key" => "value"})

      :ok = ETS.delete(session_id)

      assert {:error, :not_found} == ETS.get(session_id)
    end

    test "can delete non-existent session without error" do
      assert :ok == ETS.delete("non_existent_session")
    end
  end

  describe "TTL expiration" do
    test "expired sessions return not_found" do
      {:ok, session_id} = ETS.create()
      :ok = ETS.put(session_id, %{"key" => "value"})

      # Verify it exists first
      assert {:ok, _} = ETS.get(session_id)

      # Manually expire the session
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {session_id, %{"key" => "value"}, past_time})

      # Should return not_found for expired session
      assert {:error, :not_found} == ETS.get(session_id)
    end
  end

  describe "cleanup_expired/0" do
    test "removes expired sessions" do
      {:ok, active_id} = ETS.create()
      {:ok, expired_id} = ETS.create()

      :ok = ETS.put(active_id, %{"active" => "true"})
      :ok = ETS.put(expired_id, %{"expired" => "true"})

      # Expire one session
      past_time = System.monotonic_time(:millisecond) - 1_000_000
      :ets.insert(:proxy_sessions, {expired_id, %{"expired" => "true"}, past_time})

      count = ETS.cleanup_expired()

      assert count >= 1
      assert {:ok, _} = ETS.get(active_id)
      assert {:error, :not_found} == ETS.get(expired_id)
    end
  end
end
