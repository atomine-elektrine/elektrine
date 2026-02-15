defmodule ElektrineWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ElektrineWeb.Endpoint

      use ElektrineWeb, :verified_routes
      import Phoenix.ChannelTest
      import ElektrineWeb.ChannelCase
    end
  end

  setup tags do
    Elektrine.DataCase.setup_sandbox(tags)
    :ok
  end
end
