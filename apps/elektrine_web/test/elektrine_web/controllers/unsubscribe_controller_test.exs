defmodule ElektrineWeb.UnsubscribeControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Email.Unsubscribes

  test "one-click unsubscribe accepts signed tokens without CSRF", %{conn: conn} do
    token = Unsubscribes.generate_token("reader@example.com", "elektrine-newsletter")

    conn =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/unsubscribe/#{token}", %{"List-Unsubscribe" => "One-Click"})

    assert text_response(conn, 200) =~ "Unsubscribed successfully"
    assert Unsubscribes.unsubscribed?("reader@example.com", "elektrine-newsletter")
  end
end
