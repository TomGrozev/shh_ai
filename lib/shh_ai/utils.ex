defmodule ShhAi.Utils do
  @moduledoc """
  Shared utility functions used across the application.
  """

  @doc """
  Safely converts a string to an existing atom.

  Returns the atom if it exists, nil otherwise. Uses `String.to_existing_atom/1`
  to prevent atom table exhaustion from untrusted input.
  """
  @spec safe_to_existing_atom(String.t() | atom() | nil) :: atom() | nil
  def safe_to_existing_atom(atom) when is_atom(atom), do: atom
  def safe_to_existing_atom(nil), do: nil

  def safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  def safe_to_existing_atom(_other), do: nil

  @doc """
  Converts a NaiveDateTime to microseconds since Unix epoch.

  Returns 0 for nil or invalid input.
  """
  @spec naive_to_us(NaiveDateTime.t() | nil) :: integer()
  def naive_to_us(nil), do: 0

  def naive_to_us(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  # ── Time-boundary helpers ───────────────────────────────────────────

  @doc """
  Returns the start of today (midnight UTC) as a NaiveDateTime.
  """
  @spec today_start() :: NaiveDateTime.t()
  def today_start do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.beginning_of_day()
  end

  @doc """
  Returns the start of tomorrow (midnight UTC) as a NaiveDateTime.
  """
  @spec tomorrow_start() :: NaiveDateTime.t()
  def tomorrow_start do
    today_start() |> NaiveDateTime.add(86_400, :second)
  end

  @doc """
  Returns the start of yesterday (midnight UTC) as a NaiveDateTime.
  """
  @spec yesterday_start() :: NaiveDateTime.t()
  def yesterday_start do
    today_start() |> NaiveDateTime.add(-86_400, :second)
  end

  @doc """
  Returns a cutoff timestamp N days ago from now.
  """
  @spec days_ago_cutoff(non_neg_integer()) :: NaiveDateTime.t()
  def days_ago_cutoff(days) when is_integer(days) and days >= 0 do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-days * 86_400, :second)
    |> NaiveDateTime.truncate(:second)
  end

  @doc """
  Decodes a JSON string into a list of atoms, safely converting string keys to existing atoms.

  Returns an empty list on decode failure, nil input, or non-list JSON.
  Unknown atoms (not already loaded) are silently dropped.
  """
  @spec decode_json_atoms(binary() | nil) :: [atom()]
  def decode_json_atoms(nil), do: []

  def decode_json_atoms(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list |> Enum.map(&safe_to_existing_atom/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  def decode_json_atoms(_), do: []

  @doc """
  Decodes a JSON string into a map with atom keys, safely converting string keys to existing atoms.

  Returns an empty map on decode failure, nil input, or non-map JSON.
  Unknown keys (not already loaded) are silently dropped.
  """
  @spec decode_json_atom_map(binary() | nil) :: %{atom() => term()}
  def decode_json_atom_map(nil), do: %{}

  def decode_json_atom_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        Map.new(
          for {k, v} <- map,
              key = safe_to_existing_atom(k),
              key != nil do
            {key, v}
          end
        )

      _ ->
        %{}
    end
  end

  def decode_json_atom_map(_), do: %{}
end
