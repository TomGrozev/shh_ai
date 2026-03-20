defmodule ShhAi.SessionStore.Redis do
  @moduledoc """
  Redis-based session storage backend.
  Uses Redis with TTL for automatic session expiration.
  """

  alias ShhAi.Config

  @behaviour ShhAi.SessionStore

  @counter_key "proxy_session_counter"

  @impl true
  def create do
    session_id = generate_session_id()
    :ok = put(session_id, %{})

    {:ok, session_id}
  end

  @impl true
  def put(session_id, mapping) do
    ttl = Config.session_ttl()
    redis_key = session_key(session_id)

    command = ["SET", redis_key, Jason.encode!(mapping), "PX", to_string(ttl)]
    {:ok, _} = execute_command(command)

    :ok
  end

  @impl true
  def get(session_id) do
    redis_key = session_key(session_id)

    case execute_command(["GET", redis_key]) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, value} ->
        {:ok, Jason.decode!(value)}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete(session_id) do
    redis_key = session_key(session_id)
    {:ok, _} = execute_command(["DEL", redis_key])

    :ok
  end

  @doc """
  Initializes the Redis connection. Should be called during application startup.
  """
  @impl true
  def init do
    # Redis connection should be started as a supervised child process
    # This function is a no-op for Redis as the connection is managed externally
    :ok
  end

  defp session_key(session_id) do
    "session:#{session_id}"
  end

  defp generate_session_id do
    # Atomically increment counter using Redis INCR
    {:ok, counter} = execute_command(["INCR", @counter_key])

    # Combine with timestamp for uniqueness
    timestamp = System.system_time(:nanosecond)
    "sess_#{timestamp}_#{counter}"
  end

  defp execute_command(command) do
    if not Process.whereis(__MODULE__.Redix) do
      {:ok, _conn} = Redix.start_link(name: __MODULE__.Redix)
    end

    Redix.command(__MODULE__.Redix, command)
  end
end
