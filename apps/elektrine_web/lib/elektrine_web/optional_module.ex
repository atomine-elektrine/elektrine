defmodule ElektrineWeb.OptionalModule do
  @moduledoc false

  alias Elektrine.Platform.Modules

  def call(module_id, module, function, args, fallback) do
    if Modules.compiled?(module_id) and Modules.enabled?(module_id) and
         Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      fallback
    end
  end
end
