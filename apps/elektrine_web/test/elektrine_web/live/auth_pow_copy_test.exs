defmodule ElektrineWeb.AuthPowCopyTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous_config = Application.get_env(:elektrine, :atomine_pow, [])
    Application.put_env(:elektrine, :atomine_pow, difficulty: 8, skip_verification: false)

    on_exit(fn -> Application.put_env(:elektrine, :atomine_pow, previous_config) end)

    :ok
  end

  test "registration explains the automatic abuse check plainly", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/register")

    assert html =~ "Atomine abuse check"
    assert html =~ "work level 8"
    assert html =~ "your browser does a short calculation"
    assert html =~ "without asking you to solve a puzzle"
    refute html =~ "two-layer gate"
    refute html =~ "anonymous effort token"
  end

  test "password reset explains the automatic abuse check plainly", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/password/reset")

    assert html =~ "Atomine abuse check"
    assert html =~ "work level 8"
    assert html =~ "your browser does a short calculation"
    assert html =~ "without asking you to solve a puzzle"
    refute html =~ "two-layer gate"
    refute html =~ "anonymous effort token"
  end
end
