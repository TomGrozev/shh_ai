defmodule ShhAi.SessionStore.ETS do
  @moduledoc """
  ETS-based session storage backend.
  Uses ETS with read_concurrency for high-performance reads.
  Sessions are automatically expired via TTL.
  """

  alias ShhAi.Config

  @behaviour ShhAi.SessionStore

  @table_name :proxy_sessions
  @counter_table :proxy_session_counter

  @impl true
  def create do
    session_id = generate_session_id()
    :ok = put(session_id, %{})

    {:ok, session_id}
  end

  @impl true
  def put(session_id, mapping) do
    ttl = Config.session_ttl()
    expires_at = System.monotonic_time(:millisecond) + ttl

    :ets.insert(@table_name, {session_id, mapping, expires_at})
    :ok
  end

  @impl true
  def get(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, mapping, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, mapping}
        else
          # Session has expired
          delete(session_id)

          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete(session_id) do
    :ets.delete(@table_name, session_id)
    :ok
  end

  @doc """
  Initializes the ETS tables. Should be called during application startup.
  Can be called multiple times - will not recreate existing tables.
  """
  @impl true
  def init do
    # Create session storage table with read concurrency for performance
    # Use info to check if table exists to avoid errors on re-initialization
    case :ets.info(@table_name) do
      :undefined ->
        :ets.new(@table_name, [
          :set,
          :public,
          :named_table,
          {:keypos, 1},
          {:read_concurrency, true}
        ])

        # Create counter table for session ID generation
        :ets.new(@counter_table, [
          :set,
          :public,
          :named_table
        ])

        :ets.insert(@counter_table, {:counter, 0})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Cleans up expired sessions. Can be called periodically.
  """
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Use select_delete to efficiently remove expired sessions
    :ets.select_delete(@table_name, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp generate_session_id do
    # Atomically increment counter and generate session ID
    counter =
      :ets.update_counter(@counter_table, :counter, {2, 1})

    # Combine with timestamp for uniqueness
    timestamp = System.system_time(:nanosecond)
    "sess_#{timestamp}_#{counter}"
  end
end
