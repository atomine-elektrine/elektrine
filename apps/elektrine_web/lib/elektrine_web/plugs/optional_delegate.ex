defmodule ElektrineWeb.Plugs.OptionalDelegate do
  @moduledoc false
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, opts) do
    module = delegate_module(opts)
    delegate_opts = Keyword.get(opts, :opts, [])

    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :init, 1) and
         function_exported?(module, :call, 2) do
      module_opts = module.init(delegate_opts)
      module.call(conn, module_opts)
    else
      conn
    end
  end

  defp delegate_module(opts) do
    case Keyword.fetch(opts, :module) do
      {:ok, module} ->
        module

      :error ->
        {resolver_module, function_name} = Keyword.fetch!(opts, :resolver)
        apply(resolver_module, function_name, [Keyword.fetch!(opts, :module_name)])
    end
  end
end
