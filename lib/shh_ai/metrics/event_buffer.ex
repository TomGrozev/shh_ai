defmodule ShhAi.Metrics.EventBuffer do
  @moduledoc """
  ETS-backed ring buffer for storing recent metrics events.

  This GenServer manages an ETS table that stores the most recent N events
  in a ring buffer fashion. When the buffer is full, new events replace
  the oldest ones.

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
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores an event in the ring buffer.

  If the buffer is full, the oldest event is overwritten.
  """
  @spec store(Event.t()) :: :ok
  def store(%Event{} = event) do
    GenServer.cast(__MODULE__, {:store, event})
  end

  @doc """
  Lists recent events from the buffer.

  ## Options

    * `:limit` - Maximum number of events to return (default: 100)
    * `:provider` - Filter by source or target provider (optional)
    * `:streaming` - Filter by streaming flag (optional)
    * `:status_success` - Filter to only successful requests (optional)

  ## Examples

      iex> ShhAi.Metrics.EventBuffer.list_recent(limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

      iex> ShhAi.Metrics.EventBuffer.list_recent(provider: :openai)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_recent(keyword()) :: [Event.t()]
  def list_recent(opts \\ []) do
    GenServer.call(__MODULE__, {:list_recent, opts})
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

  ## Examples

      iex> one_hour_ago = System.system_time(:microsecond) - 3_600_000_000
      iex> ShhAi.Metrics.EventBuffer.list_since(one_hour_ago, limit: 50)
      [%ShhAi.Metrics.Event{...}, ...]

  """
  @spec list_since(integer(), keyword()) :: [Event.t()]
  def list_since(start_time, opts \\ []) do
    GenServer.call(__MODULE__, {:list_since, start_time, opts})
  end

  @doc """
  Returns the current number of events in the buffer.
  """
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @doc """
  Clears all events from the buffer.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, default_buffer_size())

    # Create ETS table with read concurrency for fast dashboard access
    :ets.new(@table_name, [
      :ordered_set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: false
    ])

    :ets.insert(@table_name, {@size_key, buffer_size})

    Logger.info("Started Metrics.EventBuffer with size #{buffer_size}")

    load_from_jsonl()

    {:ok, %{buffer_size: buffer_size}}
  end

  @impl true
  def handle_cast({:store, %Event{} = event}, state) do
    buffer_size = get_buffer_size()
    key = {event.ended_at, event.id}

    :ets.insert(@table_name, {key, event})

    enforce_size_limit(buffer_size)

    persist_to_jsonl(event)

    {:noreply, state}
  end

  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@table_name)
    :ets.insert(@table_name, {@size_key, state.buffer_size})
    {:noreply, state}
  end

  @impl true
  def handle_call({:list_recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    provider = Keyword.get(opts, :provider)
    streaming = Keyword.get(opts, :streaming)
    status_success = Keyword.get(opts, :status_success)

    events =
      take_newest(limit)
      |> apply_filters(provider, streaming, status_success)

    {:reply, events, state}
  end

  def handle_call({:list_since, start_time, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    provider = Keyword.get(opts, :provider)
    streaming = Keyword.get(opts, :streaming)
    status_success = Keyword.get(opts, :status_success)

    events =
      select_since(start_time, limit)
      |> apply_filters(provider, streaming, status_success)
      |> sort_by_recency()

    {:reply, events, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :ets.info(@table_name, :size) - 1, state}
  end

  # Private helpers

  defp default_buffer_size do
    System.get_env("METRICS_BUFFER_SIZE", "1000")
    |> String.to_integer()
  end

  defp get_buffer_size do
    :ets.lookup_element(@table_name, @size_key, 2)
  rescue
    ArgumentError -> default_buffer_size()
  end

  defp enforce_size_limit(buffer_size) do
    current_size = :ets.info(@table_name, :size) - 1

    if current_size > buffer_size do
      oldest_key = :ets.first(@table_name)

      if oldest_key != @size_key do
        :ets.delete(@table_name, oldest_key)
      end
    end
  end

  defp take_newest(limit) do
    Stream.unfold(:ets.prev(@table_name, @size_key), fn
      :"$end_of_table" ->
        nil

      key ->
        case :ets.lookup(@table_name, key) do
          [{^key, event}] -> {event, :ets.prev(@table_name, key)}
          [] -> nil
        end
    end)
    |> Enum.take(limit)
  end

  defp select_since(start_time, limit) do
    match_spec = [
      {{{:"$1", :_}, :"$2"}, [{:andalso, {:is_integer, :"$1"}, {:>=, :"$1", start_time}}],
       [:"$2"]}
    ]

    :ets.select(@table_name, match_spec, limit)
    |> case do
      :"$end_of_table" -> []
      {results, :"$end_of_table"} -> results
    end
  end

  defp apply_filters(events, nil, nil, nil), do: events

  defp apply_filters(events, provider, streaming, status_success) do
    Stream.filter(events, fn event ->
      matches_provider?(event, provider) and
        matches_streaming?(event, streaming) and
        matches_status_success?(event, status_success)
    end)
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

  defp sort_by_recency(events) do
    # Sort by ended_at descending (most recent first)
    Enum.sort_by(events, & &1.ended_at, :desc)
  end

  defp load_from_jsonl() do
    path = jsonl_file_path()
    ensure_dir_exists(path)

    Logger.info("Loading events from JSONL file: #{path}")

    buffer_size = get_buffer_size()

    case File.open(path, [:read, :utf8]) do
      {:ok, pid} ->
        try do
          events_loaded =
            IO.stream(pid, :line)
            |> Enum.reduce(0, fn line, acc ->
              event = Jason.decode!(line) |> Event.from_map()
              key = {event.ended_at, event.id}

              :ets.insert(@table_name, {key, event})

              acc + 1
            end)

          # Enforce size limit after loading all events
          enforce_size_limit_on_load(buffer_size)

          Logger.info("Loaded #{events_loaded} events from JSONL file")
        after
          File.close(pid)
        end

      {:error, _reason} ->
        Logger.debug("JSONL file does not exist yet: #{path}")
    end
  end

  defp enforce_size_limit_on_load(buffer_size) do
    current_size = :ets.info(@table_name, :size) - 1

    if current_size > buffer_size do
      # Delete oldest events (first N in ordered set)
      delete_count = current_size - buffer_size

      Stream.repeatedly(fn -> :ets.first(@table_name) end)
      |> Stream.take(delete_count)
      |> Enum.each(fn key -> :ets.delete(@table_name, key) end)
    end
  end

  defp persist_to_jsonl(%Event{} = event) do
    path = jsonl_file_path()
    ensure_dir_exists(path)

    # Append event as JSON line
    json_line = Event.to_map(event) |> Jason.encode!()

    case File.open(path, [:append, :utf8]) do
      {:ok, pid} ->
        try do
          IO.write(pid, json_line <> "\n")
        after
          File.close(pid)
        end

      {:error, reason} ->
        Logger.error("Failed to open JSONL file for appending: #{inspect(reason)}")
    end
  end

  defp jsonl_file_path do
    Path.join([Application.app_dir(:shh_ai, "priv"), "metrics", "events.jsonl"])
  end

  defp ensure_dir_exists(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
