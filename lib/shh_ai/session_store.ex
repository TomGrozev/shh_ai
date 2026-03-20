defmodule ShhAi.SessionStore do
  @moduledoc """
  Behaviour for session storage backends.
  Stores PII mappings per request with configurable TTL.
  """

  use GenServer

  require Logger

  alias ShhAi.Config

  # 10 seconds
  @cleanup_interval 10_000

  @type session_id :: String.t()
  @type mapping :: %{String.t() => String.t()}
  @type error :: {:error, term()}

  @callback init() :: :ok
  @callback create() :: {:ok, session_id()} | error()
  @callback put(session_id(), mapping()) :: :ok | error()
  @callback get(session_id()) :: {:ok, mapping()} | {:error, :not_found}
  @callback delete(session_id()) :: :ok

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the configured session store module based on configuration.
  """
  @spec backend() :: module()
  def backend do
    GenServer.call(__MODULE__, :backend)
  end

  @doc """
  Manually trigger a cleanup (useful for testing).
  Returns the number of sessions cleaned up.
  """
  @spec cleanup() :: non_neg_integer()
  def cleanup do
    GenServer.call(__MODULE__, :cleanup)
  end

  @impl true
  def init(_opts) do
    backend =
      case Config.session_store_backend() do
        :ets ->
          # Schedule the first cleanup
          schedule_cleanup()

          ShhAi.SessionStore.ETS

        :redis ->
          ShhAi.SessionStore.Redis
      end

    case backend.init() do
      :ok ->
        {:ok, %{backend: backend}}

      _ ->
        :error
    end
  end

  @impl true
  def handle_info(:cleanup, %{backend: backend} = state) do
    do_cleanup(backend)

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def handle_call(:backend, _from, %{backend: backend} = state) do
    {:reply, backend, state}
  end
  
  def handle_call(:cleanup, _from, %{backend: backend} = state) do
    res = do_cleanup(backend)

    {:reply, res, state}
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp do_cleanup(backend) do
    case backend do
      ShhAi.SessionStore.ETS ->
        ShhAi.SessionStore.ETS.cleanup_expired()

      _ ->
        # Redis handles TTL automatically
        :ok
    end
  rescue
    e ->
      Logger.error("Session cleanup failed: #{inspect(e)}")
      :error
  end

  @doc """
  Creates a new session and returns its ID.
  Delegates to the configured backend.
  """
  @spec create() :: {:ok, session_id()} | error()
  def create do
    backend().create()
  end

  @doc """
  Stores a PII mapping for a session.
  Delegates to the configured backend.
  """
  @spec put(session_id(), mapping()) :: :ok | error()
  def put(session_id, mapping) do
    backend().put(session_id, mapping)
  end

  @doc """
  Retrieves a PII mapping for a session.
  Delegates to the configured backend.
  """
  @spec get(session_id()) :: {:ok, mapping()} | {:error, :not_found}
  def get(session_id) do
    backend().get(session_id)
  end

  @doc """
  Deletes a session and its mapping.
  Delegates to the configured backend.
  """
  @spec delete(session_id()) :: :ok
  def delete(session_id) do
    backend().delete(session_id)
  end
end
