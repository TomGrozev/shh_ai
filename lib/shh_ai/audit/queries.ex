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
  alias ShhAi.Audit.ConversationMessage
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
    * `:has_pii` — boolean; filter conversations that have
      events with PII detected (`true`) or without (`false`)
  """
  @spec list_conversations(keyword()) :: [ConversationRecord.t()]
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    source_provider = Keyword.get(opts, :source_provider)
    opted_out = Keyword.get(opts, :opted_out)
    since = Keyword.get(opts, :since)
    has_pii = Keyword.get(opts, :has_pii)

    ConversationRecord
    |> order_by(desc: :last_active_at)
    |> limit(^limit)
    |> maybe_where(:source_provider, source_provider)
    |> maybe_where(:opted_out, opted_out)
    |> maybe_where_since(:last_active_at, since)
    |> maybe_where_has_pii(has_pii)
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

  @doc """
  Returns the first user message's sanitized content for each conversation.

  Returns a map of `conversation_id => sanitized_content_string | nil`.
  Conversations with no user messages map to `nil`.
  """
  @spec first_user_message_for_conversations([String.t()]) :: %{String.t() => String.t() | nil}
  def first_user_message_for_conversations([]), do: %{}

  def first_user_message_for_conversations(conversation_ids) when is_list(conversation_ids) do
    ConversationMessage
    |> where([m], m.conversation_id in ^conversation_ids and m.role == "user")
    |> order_by([m], asc: m.created_at)
    |> select([m], %{conversation_id: m.conversation_id, sanitized_content: m.sanitized_content})
    |> Repo.all()
    |> Enum.group_by(& &1.conversation_id)
    |> Map.new(fn {cid, msgs} ->
      first = hd(msgs)
      {cid, first.sanitized_content}
    end)
  end

  @doc """
  Returns a count of each PII type across all events for the given conversations.

  Returns a map of `conversation_id => %{type_atom => count}`.
  """
  @spec pii_type_counts_for_conversations([String.t()]) :: %{
          String.t() => %{atom() => non_neg_integer()}
        }
  def pii_type_counts_for_conversations([]), do: %{}

  def pii_type_counts_for_conversations(conversation_ids) when is_list(conversation_ids) do
    EventRecord
    |> where([e], e.conversation_id in ^conversation_ids)
    |> select([e], %{cid: e.conversation_id, types: e.pii_types})
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      types = decode_pii_types_list(row.types)

      type_counts =
        Enum.reduce(types, %{}, fn type, tacc ->
          Map.update(tacc, type, 1, &(&1 + 1))
        end)

      Map.update(acc, row.cid, type_counts, fn existing ->
        Map.merge(existing, type_counts, fn _k, v1, v2 -> v1 + v2 end)
      end)
    end)
  end

  @doc """
  Returns event count, total PII, and average latency for the given conversations.

  Returns a map of `conversation_id => %{event_count: int, total_pii: int, avg_latency: float}`.
  Conversations with no events are absent from the result.
  """
  @spec event_stats_for_conversations([String.t()]) :: %{
          String.t() => %{
            event_count: non_neg_integer(),
            total_pii: non_neg_integer(),
            avg_latency: float()
          }
        }
  def event_stats_for_conversations([]), do: %{}

  def event_stats_for_conversations(conversation_ids) when is_list(conversation_ids) do
    EventRecord
    |> where([e], e.conversation_id in ^conversation_ids)
    |> group_by([e], e.conversation_id)
    |> select([e], %{
      cid: e.conversation_id,
      event_count: count(e.id),
      total_pii: sum(e.pii_detected_count),
      avg_latency: avg(e.duration_ms)
    })
    |> Repo.all()
    |> Map.new(fn row ->
      {row.cid,
       %{
         event_count: row.event_count,
         total_pii: row.total_pii || 0,
         avg_latency: row.avg_latency || 0.0
       }}
    end)
  end

  @doc "Returns the count of conversations that have opted out."
  @spec count_opt_outs_handled() :: non_neg_integer()
  def count_opt_outs_handled do
    from(c in ConversationRecord, where: c.opted_out == true, select: count(c.conversation_id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Returns the count of events written for conversations that are currently opted out.

  These represent potential opt-out violations — events that should not have been
  written because the conversation opted out.
  """
  @spec count_opt_outs_not_honored() :: non_neg_integer()
  def count_opt_outs_not_honored do
    opted_out_q =
      from(c in ConversationRecord, where: c.opted_out == true, select: c.conversation_id)

    from(e in EventRecord, where: e.conversation_id in subquery(opted_out_q), select: count(e.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the count of conversations active today (last_active_at >= today start)."
  @spec count_conversations_today() :: non_neg_integer()
  def count_conversations_today do
    since = today_start()

    from(c in ConversationRecord,
      where: c.last_active_at >= ^since,
      select: count(c.conversation_id)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the total PII count detected in events today."
  @spec count_pii_detected_today() :: non_neg_integer()
  def count_pii_detected_today do
    since = today_start()

    from(e in EventRecord, where: e.inserted_at >= ^since, select: sum(e.pii_detected_count))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the total event count today."
  @spec count_total_requests_today() :: non_neg_integer()
  def count_total_requests_today do
    since = today_start()

    from(e in EventRecord, where: e.inserted_at >= ^since, select: count(e.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the average latency (ms) across all events today. Returns 0.0 if no events."
  @spec avg_latency_today() :: float()
  def avg_latency_today do
    since = today_start()

    from(e in EventRecord, where: e.inserted_at >= ^since, select: avg(e.duration_ms))
    |> Repo.one()
    |> case do
      nil -> 0.0
      val -> val
    end
  end

  # -- Private helpers --

  defp maybe_where_has_pii(query, nil), do: query

  defp maybe_where_has_pii(query, true) do
    event_sub =
      from(e in EventRecord,
        where: e.pii_detected_count > 0,
        distinct: true,
        select: e.conversation_id
      )

    from(c in query, where: c.conversation_id in subquery(event_sub))
  end

  defp maybe_where_has_pii(query, false) do
    event_sub =
      from(e in EventRecord,
        where: e.pii_detected_count > 0,
        distinct: true,
        select: e.conversation_id
      )

    from(c in query, where: c.conversation_id not in subquery(event_sub))
  end

  defp today_start do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.beginning_of_day()
  end

  defp safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp decode_pii_types_list(nil), do: []

  defp decode_pii_types_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&safe_to_existing_atom/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp decode_pii_types_list(_), do: []
end
