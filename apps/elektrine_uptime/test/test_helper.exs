unless Code.ensure_loaded?(Elektrine.DataCase) do
  Code.require_file("../test_support/data_case.ex", __DIR__)
end

unless Code.ensure_loaded?(ElektrineWeb.ConnCase) do
  Code.require_file(
    "../../elektrine_web/test/support/conn_case.ex",
    __DIR__
  )
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, :manual)
