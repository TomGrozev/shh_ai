defmodule ShhAi.Repo do
  @moduledoc """
  Ecto Repo backed by SQLite (via ecto_sqlite3).

  Used only by the Audit Mode write path (slice #23). The proxy's
  hot conversation state continues to live in ETS / Redis, untouched
  by this repo. See ADR 0001 and ADR 0010.
  """

  use Ecto.Repo, otp_app: :shh_ai, adapter: Ecto.Adapters.SQLite3
end
