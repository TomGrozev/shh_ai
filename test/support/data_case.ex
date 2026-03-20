defmodule ShhAi.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  Since this is a stateless proxy, database tests are not required.
  This module is kept for compatibility but does not setup database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing
      import ShhAi.DataCase
    end
  end

  setup _tags do
    :ok
  end
end
