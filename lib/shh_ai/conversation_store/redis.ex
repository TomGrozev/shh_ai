defmodule ShhAi.ConversationStore.Redis do
  @moduledoc """
  Redis-based storage backend for Conversations.

  Implements the `ShhAi.ConversationStore` behaviour using Redix and
  the key layout per `docs/adr/0007-conversation-tracking.md`:

    * `shh_ai:conversation:{id}` → hash with fields: `source_provider`,
      `created_at`, `last_active_at`, `provider_conversation_id`,
      `fingerprint_hash`
    * `shh_ai:conversation:{id}:mapping` → hash (`placeholder` → `original`)
    * `shh_ai:conversation:{id}:reverse_index` → hash
      (`{original_value}|{pii_type}` → `placeholder`)

  All keys use `EXPIRE` with the configured `conversation_ttl/1000` seconds.
  On `touch/1`, `last_active_at` is refreshed and all keys are re-expired.

  Mapping insertion uses `HSETNX` to match the atomic "first writer wins"
  semantics of `:ets.insert_new/2`.
  """

  @behaviour ShhAi.ConversationStore

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
            "#{original}|#{pii_type_str}",
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
            [original, pii_type_str] = String.split(k, "|", parts: 2)
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
      field = "#{original_value}|#{pii_type}"

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
    if conversation_exists?(conversation_id) do
      key = conversation_key(conversation_id)
      now = System.monotonic_time(:millisecond)
      ttl_seconds = div(Config.conversation_ttl(), 1000)

      case command(["HSET", key, "last_active_at", Integer.to_string(now)]) do
        {:ok, _} ->
          # Refresh TTL on all keys belonging to this conversation.
          commands = [
            ["EXPIRE", key, Integer.to_string(ttl_seconds)],
            ["EXPIRE", mapping_key(conversation_id), Integer.to_string(ttl_seconds)],
            ["EXPIRE", reverse_index_key(conversation_id), Integer.to_string(ttl_seconds)]
          ]

          case pipeline(commands) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @impl true
  def delete(conversation_id) do
    commands = [
      ["DEL", conversation_key(conversation_id)],
      ["DEL", mapping_key(conversation_id)],
      ["DEL", reverse_index_key(conversation_id)]
    ]

    case pipeline(commands) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def cleanup_expired do
    # Redis handles TTL automatically via EXPIRE — no manual cleanup needed.
    0
  end

  # -----------------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------------

  defp conversation_key(conversation_id), do: "#{@key_prefix}#{conversation_id}"
  defp mapping_key(conversation_id), do: "#{@key_prefix}#{conversation_id}:mapping"
  defp reverse_index_key(conversation_id), do: "#{@key_prefix}#{conversation_id}:reverse_index"

  defp conversation_exists?(conversation_id) do
    case command(["EXISTS", conversation_key(conversation_id)]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  defp command(args) do
    Redix.command(ShhAi.Redis, args)
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
      ArgumentError -> String.to_atom(str)
    end
  end
end
