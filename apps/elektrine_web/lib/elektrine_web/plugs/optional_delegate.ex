defmodule ElektrineWeb.Plugs.OptionalDelegate do
  @moduledoc false
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, opts) do
    module = Keyword.fetch!(opts, :module)
    delegate_opts = Keyword.get(opts, :opts, [])

    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :call, 2) do
      module_opts = module.init(delegate_opts)
      module.call(conn, module_opts)
    else
      conn
    end
  end
end
