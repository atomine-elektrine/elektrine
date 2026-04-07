defmodule ElektrineWeb.Plugs.OptionalDelegateTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias ElektrineWeb.Plugs.OptionalDelegate

  defmodule DemoDelegate do
    def init(opts), do: opts

    def call(conn, _opts) do
      assign(conn, :delegated, true)
    end
  end

  defmodule DemoResolver do
    def optional_delegate(:demo), do: ElektrineWeb.Plugs.OptionalDelegateTest.DemoDelegate
    def optional_delegate(_name), do: nil
  end

  test "delegates through resolver-provided module" do
    conn = Plug.Test.conn(:get, "/")

    conn =
      OptionalDelegate.call(conn,
        resolver: {DemoResolver, :optional_delegate},
        module_name: :demo,
        opts: []
      )

    assert conn.assigns.delegated == true
  end

  test "no-ops when resolver returns no module" do
    conn = Plug.Test.conn(:get, "/")

    conn =
      OptionalDelegate.call(conn,
        resolver: {DemoResolver, :optional_delegate},
        module_name: :missing,
        opts: []
      )

    refute Map.has_key?(conn.assigns, :delegated)
  end
end
