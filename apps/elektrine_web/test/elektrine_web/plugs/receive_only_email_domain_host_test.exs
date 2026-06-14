defmodule ElektrineWeb.Plugs.ReceiveOnlyEmailDomainHostTest do
  use ElektrineWeb.ConnCase, async: false

  setup do
    previous_email_config = Application.get_env(:elektrine, :email, [])

    Application.put_env(
      :elektrine,
      :email,
      Keyword.merge(previous_email_config,
        domain: "elektrine.test",
        supported_domains: ["elektrine.test", "example.org"]
      )
    )

    on_exit(fn -> Application.put_env(:elektrine, :email, previous_email_config) end)

    :ok
  end

  test "blocks the root secondary email domain", %{conn: conn} do
    conn = conn |> Map.put(:host, "example.org") |> get("/")

    assert response(conn, 404) == "Not found"
    assert conn.halted
  end

  test "blocks secondary email subdomains", %{conn: conn} do
    conn = conn |> Map.put(:host, "alice.example.org") |> get("/")

    assert response(conn, 404) == "Not found"
    assert conn.halted
  end
end
