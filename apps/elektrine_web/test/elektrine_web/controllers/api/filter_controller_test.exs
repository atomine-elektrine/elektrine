defmodule ElektrineWeb.API.FilterControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Social.Filters
  alias ElektrineWeb.API.FilterController

  describe "show/2" do
    test "shows a filter owned by the current user", %{conn: conn} do
      user = user_fixture()

      {:ok, filter} =
        Filters.create_filter(user.id, %{
          kind: "keyword",
          value: "spoilers",
          contexts: ["home"],
          action: "warn",
          whole_word: true
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> FilterController.show(%{"id" => filter.id})

      assert %{
               "id" => id,
               "title" => "spoilers",
               "kind" => "keyword",
               "value" => "spoilers",
               "context" => ["home"],
               "filter_action" => "warn",
               "whole_word" => true,
               "keywords" => [%{"keyword" => "spoilers", "whole_word" => true}]
             } = json_response(conn, 200)

      assert id == to_string(filter.id)
    end

    test "does not expose another user's filter", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, filter} =
        Filters.create_filter(owner.id, %{
          kind: "keyword",
          value: "private"
        })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> FilterController.show(%{"id" => filter.id})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end
end
