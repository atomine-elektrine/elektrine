Code.require_file("support/data_case.ex", __DIR__)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, :manual)
