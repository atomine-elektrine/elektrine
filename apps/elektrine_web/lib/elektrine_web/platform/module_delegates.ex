defmodule ElektrineWeb.Platform.ModuleDelegates do
  @moduledoc false

  alias Elektrine.Platform.ModuleProviders

  def optional_delegate(name) when is_atom(name) do
    ModuleProviders.optional_delegate(name)
  end
end
