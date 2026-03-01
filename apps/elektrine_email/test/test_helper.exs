unless Code.ensure_loaded?(Elektrine.DataCase) do
  Code.require_file("support/data_case.ex", __DIR__)
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, :manual)
