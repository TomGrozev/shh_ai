defmodule ShhAi.Audit.Queries do
  @moduledoc """
  Read-only Ecto query functions for the Audit Mode dashboard.

  These functions read from the Audit Mode SQLite tables
  (`conversations`, `events`) populated by `ShhAi.Audit.Writer`.
  They are the single source of truth for the dashboard's
  conversation view; the dashboard polls this module every 5s
  instead of subscribing to PubSub for per-event freshness.

  See issue #27.
  """

  import Ecto.Query
  alias ShhAi.Audit.ConversationRecord
  alias ShhAi.Audit.EventRecord
  alias ShhAi.Config
  alias ShhAi.Repo

  @default_limit 50

  @doc "Returns the current Audit Mode state."
  @spec audit_mode?() :: boolean()
  def audit_mode?, do: Config.audit_mode?()

  @doc """
  Lists conversations from the audit `conversations` table,
  most-recently-active first.

  ## Options

    * `:limit` — maximum number of rows (default 50)
    * `:source_provider` — string, e.g. "openai"
    * `:opted_out` — boolean; filter rows with this exact value
    * `:since` — `NaiveDateTime`; only rows with
      `last_active_at >= since` are returned
  """
  @spec list_conversations(keyword()) :: [ConversationRecord.t()]
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    source_provider = Keyword.get(opts, :source_provider)
    opted_out = Keyword.get(opts, :opted_out)
    since = Keyword.get(opts, :since)

    ConversationRecord
    |> order_by(desc: :last_active_at)
    |> limit(^limit)
    |> maybe_where(:source_provider, source_provider)
    |> maybe_where(:opted_out, opted_out)
    |> maybe_where_since(:last_active_at, since)
    |> Repo.all()
  end

  @doc """
  Lists events from the audit `events` table, newest first.

  ## Options

    * `:limit` — maximum number of rows (default 50)
    * `:conversation_id` — string OR `nil`; `nil` matches
      rows where `conversation_id IS NULL`
    * `:since` — `NaiveDateTime`; only rows with
      `inserted_at >= since` are returned
  """
  @spec list_events(keyword()) :: [EventRecord.t()]
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    since = Keyword.get(opts, :since)

    EventRecord
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> maybe_filter_conversation_id(opts)
    |> maybe_where_since(:inserted_at, since)
    |> Repo.all()
  end

  # conversation_id is special: passing `nil` explicitly means
  # "WHERE conversation_id IS NULL", while omitting the key means
  # "don't filter on conversation_id". Keyword.get/3 returns nil in
  # both cases, so we must check key presence. Also, Ecto forbids
  # comparing a field with nil via `== ^value`; we must use `is_nil/1`.
  defp maybe_filter_conversation_id(query, opts) do
    if Keyword.has_key?(opts, :conversation_id) do
      case Keyword.fetch!(opts, :conversation_id) do
        nil -> from(r in query, where: is_nil(field(r, ^:conversation_id)))
        value -> from(r in query, where: field(r, ^:conversation_id) == ^value)
      end
    else
      query
    end
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) do
    from(r in query, where: field(r, ^field) == ^value)
  end

  defp maybe_where_since(query, _field, nil), do: query

  defp maybe_where_since(query, field, %NaiveDateTime{} = since) do
    from(r in query, where: field(r, ^field) >= ^since)
  end

  @doc """
  Returns aggregated event counts and PII totals for the given list of
  `conversation_id`s, as a map `%{conversation_id => %{event_count: int, total_pii: int}}`.

  Conversations with no events are absent from the result. Callers should
  look up with `Map.get/3` and provide defaults.

  This is intended for the dashboard's per-conversation metadata: it lets
  the conversation list show turn counts and PII totals without an N+1
  event query per row.
  """
  @spec count_metadata_for_conversations([String.t()]) :: %{
          String.t() => %{event_count: non_neg_integer(), total_pii: non_neg_integer()}
        }
  def count_metadata_for_conversations([]), do: %{}

  def count_metadata_for_conversations(conversation_ids) when is_list(conversation_ids) do
    EventRecord
    |> where([e], e.conversation_id in ^conversation_ids)
    |> group_by([e], e.conversation_id)
    |> select([e], %{
      conversation_id: e.conversation_id,
      event_count: count(e.id),
      total_pii: sum(e.pii_detected_count)
    })
    |> Repo.all()
    |> Map.new(fn row ->
      {row.conversation_id, %{event_count: row.event_count, total_pii: row.total_pii || 0}}
    end)
  end
end
