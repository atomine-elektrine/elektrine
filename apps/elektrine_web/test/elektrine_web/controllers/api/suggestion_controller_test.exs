defmodule ElektrineWeb.API.SuggestionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Profiles
  alias ElektrineWeb.API.SuggestionController

  import Elektrine.AccountsFixtures

  describe "index/2" do
    test "returns suggested accounts for the current user", %{conn: conn} do
      viewer = user_fixture()
      follower = user_fixture()
      followed = user_fixture()
      suggested = user_fixture(%{username: "suggestedfollow"})

      assert {:ok, _follow} = Profiles.follow_user(follower.id, suggested.id)
      assert {:ok, _follow} = Profiles.follow_user(suggested.id, followed.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SuggestionController.index(%{"limit" => "10"})

      suggestions = json_response(conn, 200)

      assert %{
               "source" => "past_interactions",
               "sources" => ["past_interactions"],
               "reason" => "Popular user",
               "account" => %{
                 "id" => id,
                 "username" => "suggestedfollow",
                 "acct" => "suggestedfollow",
                 "followers_count" => 1,
                 "following_count" => 1,
                 "statuses_count" => 0,
                 "remote" => false
               }
             } =
               Enum.find(suggestions, fn suggestion ->
                 get_in(suggestion, ["account", "username"]) == "suggestedfollow"
               end)

      assert id == to_string(suggested.id)
    end
  end

  describe "dismiss/2" do
    test "dismisses suggested accounts and excludes them from future suggestions", %{conn: conn} do
      viewer = user_fixture()
      follower = user_fixture()
      suggested = user_fixture(%{username: "dismisssuggested"})

      assert {:ok, _follow} = Profiles.follow_user(follower.id, suggested.id)

      list_conn =
        conn
        |> assign(:current_user, viewer)
        |> SuggestionController.index(%{"limit" => "10"})

      assert [
               %{"account" => %{"id" => suggested_id, "username" => "dismisssuggested"}}
             ] = json_response(list_conn, 200)

      assert suggested_id == to_string(suggested.id)

      dismiss_conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> SuggestionController.dismiss(%{"account_id" => to_string(suggested.id)})

      assert %{} = json_response(dismiss_conn, 200)

      dismissed_list_conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> SuggestionController.index(%{"limit" => "10"})

      assert [] = json_response(dismissed_list_conn, 200)
    end

    test "dismissal is idempotent", %{conn: conn} do
      viewer = user_fixture()
      suggested = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SuggestionController.dismiss(%{"account_id" => to_string(suggested.id)})

      assert %{} = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> SuggestionController.dismiss(%{"account_id" => to_string(suggested.id)})

      assert %{} = json_response(conn, 200)
    end
  end
end
