defmodule ElektrineWeb.HealthControllerTest do
  use ElektrineWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 OK with status", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "returns JSON content type", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end
end
