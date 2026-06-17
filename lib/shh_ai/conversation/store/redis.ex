defmodule ShhAi.Conversation.Store.Redis do
  @moduledoc """
  Redis-based storage backend for Conversations.

  Implements the `ShhAi.Conversation.Store` behaviour using Redix and
  the key layout per `docs/adr/0007-conversation-tracking.md`:

    * `shh_ai:conversation:{id}` → hash with fields: `source_provider`,
      `created_at`, `last_active_at`, `provider_conversation_id`,
      `fingerprint_hash`
    * `shh_ai:conversation:{id}:mapping` → hash (`placeholder` → `original`)
    * `shh_ai:conversation:{id}:reverse_index` → hash
      (`{original_value}\0{pii_type}` → `placeholder`)

  All keys use `EXPIRE` with the configured `conversation_ttl/1000` seconds.
  On `touch/1`, `last_active_at` is refreshed and all keys are re-expired.

  Mapping insertion uses `HSETNX` to match the atomic "first writer wins"
  semantics of `:ets.insert_new/2`.
  """

  @behaviour ShhAi.Conversation.Store

  alias ShhAi.Config

  @key_prefix "shh_ai:conversation:"

  # -----------------------------------------------------------------------
  # Behaviour callbacks
  # -----------------------------------------------------------------------

  @impl true
  def init do
    # Ensure a Redix connection is available. If `ShhAi.Redis` is already
    # started (e.g. by the application supervisor), this is a no-op.
    case Process.whereis(ShhAi.Redis) do
      nil ->
        case Redix.start_link(Config.redis_url(), name: ShhAi.Redis) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      _pid ->
        :ok
    end
  end

  @impl true
  def create(conversation) do
    key = conversation_key(conversation.conversation_id)
    ttl_seconds = div(Config.conversation_ttl(), 1000)

    commands = [
      [
        "HSET",
        key,
        "source_provider",
        to_string(conversation.source_provider),
        "created_at",
        Integer.to_string(conversation.created_at),
        "last_active_at",
        Integer.to_string(conversation.last_active_at),
        "provider_conversation_id",
        to_string(conversation.provider_conversation_id || ""),
        "fingerprint_hash",
        to_string(conversation.fingerprint_hash || "")
      ],
      ["EXPIRE", key, Integer.to_string(ttl_seconds)]
    ]

    case pipeline(commands) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def add_mapping(conversation_id, mapping_entries, reverse_index_entries) do
    mapping_key = mapping_key(conversation_id)
    reverse_key = reverse_index_key(conversation_id)
    ttl_seconds = div(Config.conversation_ttl(), 1000)

    commands =
      Enum.map(mapping_entries, fn {placeholder, original} ->
        ["HSETNX", mapping_key, serialize_placeholder_key(placeholder), original]
      end) ++
        Enum.map(reverse_index_entries, fn {{original, pii_type}, placeholder} ->
          pii_type_str = to_string(pii_type)

          [
            "HSETNX",
            reverse_key,
            "#{original}\0#{pii_type_str}",
            serialize_placeholder_key(placeholder)
          ]
        end) ++
        [
          ["EXPIRE", conversation_key(conversation_id), Integer.to_string(ttl_seconds)],
          ["EXPIRE", mapping_key, Integer.to_string(ttl_seconds)],
          ["EXPIRE", reverse_key, Integer.to_string(ttl_seconds)]
        ]

    case pipeline(commands) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_mapping(conversation_id) do
    key = mapping_key(conversation_id)

    case command(["HGETALL", key]) do
      {:ok, []} ->
        # Key may not exist — verify the conversation exists first.
        if conversation_exists?(conversation_id) do
          {:ok, %{}}
        else
          {:error, :not_found}
        end

      {:ok, pairs} ->
        mapping =
          pairs
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {deserialize_key(k), v} end)

        {:ok, mapping}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_reverse_index(conversation_id) do
    key = reverse_index_key(conversation_id)

    case command(["HGETALL", key]) do
      {:ok, []} ->
        if conversation_exists?(conversation_id) do
          {:ok, %{}}
        else
          {:error, :not_found}
        end

      {:ok, pairs} ->
        reverse_index =
          pairs
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] ->
            [original, pii_type_str] = String.split(k, "\0", parts: 2)
            {{original, safe_to_atom(pii_type_str)}, deserialize_key(v)}
          end)

        {:ok, reverse_index}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def lookup_placeholder(conversation_id, original_value, pii_type) do
    if conversation_exists?(conversation_id) do
      key = reverse_index_key(conversation_id)
      field = "#{original_value}\0#{pii_type}"

      case command(["HGET", key, field]) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, placeholder} -> {:ok, deserialize_key(placeholder)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @impl true
  def touch(conversation_id) do
    key = conversation_key(conversation_id)
    now = System.monotonic_time(:millisecond)
    ttl_seconds = div(Config.conversation_ttl(), 1000)

    # Check existence first — HSET return value (fields newly added) cannot
    # reliably indicate whether the key existed.
    case command(["EXISTS", key]) do
      {:ok, 0} ->
        {:error, :not_found}

      {:ok, 1} ->
        commands = [
          ["HSET", key, "last_active_at", Integer.to_string(now)],
          ["EXPIRE", key, Integer.to_string(ttl_seconds)],
          ["EXPIRE", mapping_key(conversation_id), Integer.to_string(ttl_seconds)],
          ["EXPIRE", reverse_index_key(conversation_id), Integer.to_string(ttl_seconds)],
          ["EXPIRE", message_cache_key(conversation_id), Integer.to_string(ttl_seconds)]
        ]

        case pipeline(commands) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_conversation(conversation_id) do
    key = conversation_key(conversation_id)

    case command(["HGETALL", key]) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, pairs} ->
        fields =
          pairs
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        {:ok, mapping} = get_mapping(conversation_id)
        {:ok, reverse_index} = get_reverse_index(conversation_id)

        source_provider =
          fields
          |> Map.get("source_provider", "")
          |> safe_to_atom()

        provider_conversation_id =
          case Map.get(fields, "provider_conversation_id", "") do
            "" -> nil
            val -> val
          end

        fingerprint_hash =
          case Map.get(fields, "fingerprint_hash", "") do
            "" -> nil
            val -> val
          end

        {:ok,
         %ShhAi.Conversation{
           conversation_id: conversation_id,
           source_provider: source_provider,
           created_at: String.to_integer(Map.get(fields, "created_at", "0")),
           last_active_at: String.to_integer(Map.get(fields, "last_active_at", "0")),
           provider_conversation_id: provider_conversation_id,
           fingerprint_hash: fingerprint_hash,
           mapping: mapping,
           reverse_index: reverse_index,
           new?: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def update_fingerprint(conversation_id, fingerprint_hash) do
    key = conversation_key(conversation_id)

    case command(["EXISTS", key]) do
      {:ok, 1} ->
        case command(["HSET", key, "fingerprint_hash", fingerprint_hash]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, 0} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(conversation_id) do
    commands = [
      ["DEL", conversation_key(conversation_id)],
      ["DEL", mapping_key(conversation_id)],
      ["DEL", reverse_index_key(conversation_id)],
      ["DEL", message_cache_key(conversation_id)]
    ]

    case pipeline(commands) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def cache_message(conversation_id, message_hash, sanitized_content) do
    key = message_cache_key(conversation_id)
    ttl_seconds = div(Config.conversation_ttl(), 1000)

    commands = [
      ["HSET", key, message_hash, :erlang.term_to_binary(sanitized_content)],
      ["EXPIRE", key, Integer.to_string(ttl_seconds)]
    ]

    case pipeline(commands) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def lookup_message(conversation_id, message_hash) do
    key = message_cache_key(conversation_id)

    case command(["HGET", key, message_hash]) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, binary} ->
        try do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
        rescue
          ArgumentError -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cleanup_expired do
    # Redis handles TTL automatically via EXPIRE — no manual cleanup needed.
    0
  end

  @impl true
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    # Use SCAN instead of KEYS for non-blocking iteration.
    # SCAN cursor [MATCH pattern] [COUNT hint]
    case scan_keys("#{@key_prefix}*", []) do
      {:ok, keys} ->
        # Filter to only base conversation keys (not :mapping, :reverse_index, :message_cache)
        conversation_keys =
          keys
          |> Enum.filter(fn key ->
            not String.ends_with?(key, ":mapping") and
              not String.ends_with?(key, ":reverse_index") and
              not String.ends_with?(key, ":message_cache")
          end)

        conversation_keys
        |> Stream.map(&fetch_or_nil/1)
        |> Stream.reject(&is_nil/1)
        |> Enum.sort_by(& &1.last_active_at, :desc)
        |> Enum.take(limit)

      {:error, reason} ->
        require Logger
        Logger.error("Redis list_conversations failed: #{inspect(reason)}")
        []
    end
  end

  defp fetch_or_nil(key) do
    conversation_id = String.trim_leading(key, @key_prefix)

    case get_conversation(conversation_id) do
      {:ok, conv} -> conv
      {:error, _} -> nil
    end
  end

  # -----------------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------------

  defp conversation_key(conversation_id), do: "#{@key_prefix}#{conversation_id}"
  defp mapping_key(conversation_id), do: "#{@key_prefix}#{conversation_id}:mapping"
  defp reverse_index_key(conversation_id), do: "#{@key_prefix}#{conversation_id}:reverse_index"
  defp message_cache_key(conversation_id), do: "#{@key_prefix}#{conversation_id}:message_cache"

  defp conversation_exists?(conversation_id) do
    case command(["EXISTS", conversation_key(conversation_id)]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  defp command(args) do
    Redix.command(ShhAi.Redis, args)
  end

  # Non-blocking SCAN-based key iteration, replacing O(N) KEYS.
  # Returns {:ok, all_keys} or {:error, reason}.
  defp scan_keys(pattern, acc, cursor \\ "0") do
    case command(["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [new_cursor, keys]} ->
        all_keys = acc ++ keys

        if new_cursor == "0" do
          {:ok, all_keys}
        else
          scan_keys(pattern, all_keys, new_cursor)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pipeline(commands) do
    Redix.pipeline(ShhAi.Redis, commands)
  end

  defp serialize_placeholder_key({type, count}) when is_atom(type) and is_integer(count) do
    "#{type |> to_string() |> String.upcase()}_#{count}"
  end

  defp serialize_placeholder_key(bin) when is_binary(bin), do: bin

  defp deserialize_key(str) when is_binary(str) do
    [type_str, num_str | _] = String.split(str, "_", parts: 2)
    {String.downcase(type_str) |> safe_to_atom(), String.to_integer(num_str)}
  end

  defp safe_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> :unknown
    end
  end
end
