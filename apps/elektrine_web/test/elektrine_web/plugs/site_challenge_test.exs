defmodule ElektrineWeb.Plugs.SiteChallengeTest do
  use ElektrineWeb.ConnCase, async: false

  setup do
    previous_config = Application.get_env(:elektrine, :atomine_gate, [])
    on_exit(fn -> Application.put_env(:elektrine, :atomine_gate, previous_config) end)
    :ok
  end

  defp enable_site_challenge do
    Application.put_env(:elektrine, :atomine_gate, site_enabled: true)
  end

  test "off by default: anonymous HTML requests pass through", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "About"
  end

  test "challenges anonymous browser requests when enabled", %{conn: conn} do
    enable_site_challenge()

    conn =
      conn
      |> put_req_header("accept", "text/html,application/xhtml+xml")
      |> get(~p"/about")

    assert conn.status == 403
    assert conn.halted
    assert conn.resp_body =~ "Checking your browser"
    assert conn.resp_body =~ ~s(name="gate_scope" value="site")
  end

  test "challenges clients with no accept header when enabled", %{conn: conn} do
    enable_site_challenge()

    conn = get(conn, ~p"/about")

    assert conn.status == 403
    assert conn.resp_body =~ "Checking your browser"
  end

  test "does not challenge sessions holding a user token", %{conn: conn} do
    enable_site_challenge()

    conn =
      conn
      |> init_test_session(%{user_token: "session-token"})
      |> put_req_header("accept", "text/html")
      |> get(~p"/about")

    refute conn.status == 403
    refute (conn.resp_body || "") =~ "Checking your browser"
  end

  test "does not challenge ActivityPub content negotiation", %{conn: conn} do
    enable_site_challenge()

    # Reaching the route's own `accepts ["html"]` plug (which raises for
    # activity+json) proves SiteChallenge passed the request through instead
    # of halting with the 403 interstitial.
    assert_raise Phoenix.NotAcceptableError, fn ->
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get(~p"/about")
    end
  end

  test "does not intercept non-GET requests", %{conn: conn} do
    enable_site_challenge()

    conn = post(conn, ~p"/login", %{})

    refute conn.resp_body =~ "Checking your browser"
  end
end
