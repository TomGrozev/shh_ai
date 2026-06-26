defmodule ShhAi.Metrics.EventBuffer do
  @moduledoc """
  ETS-backed ring buffer for storing recent metrics events.

  This GenServer manages an ETS table that stores the most recent N events
  in a ring buffer fashion. When the buffer is full, new events replace
  the oldest ones. After each successful ETS insert the buffer casts
  `{:write_event, event}` to `ShhAi.Audit.Writer`, which persists the
  event to the Cold Store SQLite `events` table when Audit Mode is ON.

  ## Persistence model

    * **In-memory**: Every stored event lives in the ETS ring buffer
      (capped at `METRICS_BUFFER_SIZE`, default 1000) for the lifetime of
      the process. Used by the dashboard.
    * **Audit Mode ON**: `ShhAi.Audit.Writer` inserts a row into the
      `events` SQLite table. `pii_types`, `timings`, and `error` columns
      are JSON-encoded.
    * **Audit Mode OFF**: The Writer's `write_event` cast is a no-op.
      Events are NOT persisted to disk; they are ephemeral.

  ## Configuration

  The buffer size can be configured via environment variable:

      METRICS_BUFFER_SIZE=1000

  Or defaults to 1000 events.

  ## Usage

      # Start the buffer (typically in your application supervisor)
      ShhAi.Metrics.EventBuffer.start_link(buffer_size: 1000)

      # Store an event
      ShhAi.Metrics.EventBuffer.store(%ShhAi.Metrics.Event{...})

      # List recent events
      ShhAi.Metrics.EventBuffer.list_recent(limit: 50, provider: :openai)

  """

  use GenServer

  require Logger

  alias ShhAi.Metrics.Event

  @table_name __MODULE__.Table
  @size_key {:__MODULE__, :size}

  @type option ::
          {:buffer_size, pos_integer()}
          | {:name, atom()}

  @doc """
  Starts the EventBuffer GenServer.

  ## Options

    * `:buffer_size` - Maximum number of events to keep (default: 1000)
    * `:name` - Registered name for the GenServer (default: __MODULE__)

  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put_new(opts, :name, name), name: name)
  end

  @doc """
  Stores an event in the ring buffer.

  If the buffer is full, the oldest event is overwritten.
  """
  @spec store(Event.t(), keyword()) :: :ok
  def store(%Event{} = event, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.cast(name, {:store, event})
  end

  @doc """
  Lists recent events from the buffer.

  ## Options

    * `:limit` - Maximum number of events to return (default: 100)
    * `:provider` - Filter by source or target provider (optional)
    * `:streaming` - Filter by streaming flag (optional)
    * `:status_success` - Filter to only successful requests (optional)
    * `:conversation_id` - Filter by conversation ID (optional)

  ## Examples

      iex> ShhAi.Metrics.EventBuffer.list_recent(limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

      iex> ShhAi.Metrics.EventBuffer.list_recent(provider: :openai)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_recent(keyword()) :: [Event.t()]
  def list_recent(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:list_recent, opts})
  end

  @doc """
  Lists events since a given timestamp.

  Returns all events where `ended_at >= start_time`, up to the specified limit.

  ## Parameters

    * `start_time` - Unix timestamp in microseconds (from `System.system_time(:microsecond)`)
    * `opts` - Keyword list of options

  ## Options

    * `:limit` - Maximum number of events to return (default: 100)
    * `:provider` - Filter by source or target provider (optional)
    * `:streaming` - Filter by streaming flag (optional)
    * `:status_success` - Filter to only successful requests (optional)
    * `:conversation_id` - Filter by conversation ID (optional)

  ## Examples

      iex> one_hour_ago = System.system_time(:microsecond) - 3_600_000_000
      iex> ShhAi.Metrics.EventBuffer.list_since(one_hour_ago, limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_since(integer(), keyword()) :: [Event.t()]
  def list_since(start_time, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:list_since, start_time, opts})
  end

  @doc """
  Returns the current number of events in the buffer.
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :count)
  end

  @doc """
  Clears all events from the buffer.
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :clear)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, default_buffer_size())
    name = Keyword.get(opts, :name, __MODULE__)
    table_name = derive_table_name(name)

    # Create ETS table with read concurrency for fast dashboard access,
    # or reuse an existing one (useful in test environments).
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [
          :ordered_set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: false
        ])

      _ ->
        :ok
    end

    :ets.insert(table_name, {@size_key, buffer_size})

    Logger.info("Started Metrics.EventBuffer with size #{buffer_size}")

    {:ok, %{buffer_size: buffer_size, table_name: table_name, name: name}}
  end

  @impl true
  def handle_cast({:store, %Event{} = event}, state) do
    buffer_size = get_buffer_size(state.table_name)
    key = {event.ended_at, event.id}

    :ets.insert(state.table_name, {key, event})

    enforce_size_limit(state.table_name, buffer_size)

    # Fire-and-forget persist to the Audit Mode Cold Store. The Writer
    # early-bails cheaply when AUDIT_MODE is off (no JSONL fallback — see
    # issue #25). The cast target is a process that is always running
    # because the application supervisor starts ShhAi.Audit.Writer
    # unconditionally.
    if pid = Process.whereis(ShhAi.Audit.Writer) do
      GenServer.cast(pid, {:write_event, event})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    ensure_table(state)
    :ets.delete_all_objects(state.table_name)
    :ets.insert(state.table_name, {@size_key, state.buffer_size})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    provider = Keyword.get(opts, :provider)
    streaming = Keyword.get(opts, :streaming)
    status_success = Keyword.get(opts, :status_success)
    conversation_id = Keyword.get(opts, :conversation_id)

    events =
      state.table_name
      |> take_newest(limit)
      |> apply_filters(provider, streaming, status_success, conversation_id)

    {:reply, events, state}
  end

  def handle_call({:list_since, start_time, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    provider = Keyword.get(opts, :provider)
    streaming = Keyword.get(opts, :streaming)
    status_success = Keyword.get(opts, :status_success)
    conversation_id = Keyword.get(opts, :conversation_id)

    events =
      state.table_name
      |> select_since(start_time, limit)
      |> apply_filters(provider, streaming, status_success, conversation_id)
      |> sort_by_recency()

    {:reply, events, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table_name, :size) - 1, state}
  end

  # Private helpers

  defp ensure_table(state) do
    case :ets.whereis(state.table_name) do
      :undefined ->
        :ets.new(state.table_name, [
          :ordered_set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: false
        ])

        :ets.insert(state.table_name, {@size_key, state.buffer_size})
        Logger.info("Recreated ETS table #{inspect(state.table_name)}")

      _ ->
        :ok
    end
  end

  defp derive_table_name(name) when is_atom(name) do
    if name == __MODULE__ do
      @table_name
    else
      String.to_atom("#{Atom.to_string(__MODULE__)}.Table.#{Atom.to_string(name)}")
    end
  end

  defp default_buffer_size do
    System.get_env("METRICS_BUFFER_SIZE", "1000")
    |> String.to_integer()
  end

  defp get_buffer_size(table_name) do
    :ets.lookup_element(table_name, @size_key, 2)
  rescue
    ArgumentError -> default_buffer_size()
  end

  defp enforce_size_limit(table_name, buffer_size) do
    current_size = :ets.info(table_name, :size) - 1

    if current_size > buffer_size do
      oldest_key = :ets.first(table_name)

      if oldest_key != @size_key do
        :ets.delete(table_name, oldest_key)
      end
    end
  end

  defp take_newest(table_name, limit) do
    Stream.unfold(:ets.prev(table_name, @size_key), fn
      :"$end_of_table" ->
        nil

      key ->
        case :ets.lookup(table_name, key) do
          [{^key, event}] -> {event, :ets.prev(table_name, key)}
          [] -> nil
        end
    end)
    |> Enum.take(limit)
  end

  defp select_since(table_name, start_time, limit) do
    match_spec = [
      {{{:"$1", :_}, :"$2"}, [{:andalso, {:is_integer, :"$1"}, {:>=, :"$1", start_time}}],
       [:"$2"]}
    ]

    :ets.select(table_name, match_spec, limit)
    |> case do
      :"$end_of_table" -> []
      {results, :"$end_of_table"} -> results
      {results, _continuation} -> results
    end
  end

  defp apply_filters(events, nil, nil, nil, nil), do: events

  defp apply_filters(events, provider, streaming, status_success, conversation_id) do
    events
    |> Stream.filter(fn event ->
      matches_provider?(event, provider) and
        matches_streaming?(event, streaming) and
        matches_status_success?(event, status_success) and
        matches_conversation_id?(event, conversation_id)
    end)
    |> Enum.to_list()
  end

  defp matches_provider?(_event, nil), do: true

  defp matches_provider?(event, provider) when is_atom(provider) do
    event.source_provider == provider or event.target_provider == provider
  end

  defp matches_streaming?(_event, nil), do: true

  defp matches_streaming?(event, streaming) when is_boolean(streaming),
    do: event.streaming == streaming

  defp matches_status_success?(_event, nil), do: true

  defp matches_status_success?(event, true) when is_integer(event.status) do
    event.status >= 200 and event.status < 300
  end

  defp matches_status_success?(event, false) when is_integer(event.status) do
    event.status < 200 or event.status >= 400
  end

  defp matches_status_success?(_event, _), do: true

  defp matches_conversation_id?(_event, nil), do: true

  defp matches_conversation_id?(event, conversation_id) when is_binary(conversation_id),
    do: event.conversation_id == conversation_id

  defp sort_by_recency(events) do
    # Sort by ended_at descending (most recent first)
    Enum.sort_by(events, & &1.ended_at, :desc)
  end
end
