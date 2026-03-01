unless Code.ensure_loaded?(Elektrine.DataCase) do
  Code.require_file("support/data_case.ex", __DIR__)
end

unless Code.ensure_loaded?(Elektrine.AccountsFixtures) do
  Code.require_file("support/fixtures/accounts_fixtures.ex", __DIR__)
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, :manual)
