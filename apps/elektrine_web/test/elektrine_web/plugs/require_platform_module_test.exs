defmodule ElektrineWeb.Plugs.RequirePlatformModuleTest do
  use ElektrineWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:elektrine, :platform_modules)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:elektrine, :platform_modules)
      else
        Application.put_env(:elektrine, :platform_modules, original)
      end
    end)

    :ok
  end

  test "returns 404 for disabled browser modules", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    conn = get(conn, ~p"/email")

    assert response(conn, 404)
  end

  test "keeps enabled browser modules routable", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    conn = get(conn, ~p"/chat")

    assert redirected_to(conn) == ~p"/login"
  end

  test "returns 404 for disabled API modules", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:social])

    conn = get(conn, "/api/ext/v1/email/messages")

    assert response(conn, 404)
  end
end
