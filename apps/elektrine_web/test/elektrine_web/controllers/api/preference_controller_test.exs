defmodule ElektrineWeb.API.PreferenceControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias ElektrineWeb.API.PreferenceController

  import Elektrine.AccountsFixtures

  describe "show/2" do
    test "returns social posting and reading preferences", %{conn: conn} do
      {:ok, user} =
        user_fixture()
        |> Accounts.update_user(%{
          default_post_visibility: "public",
          locale: "zh"
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> PreferenceController.show(%{})

      assert %{
               "posting:default:visibility" => "public",
               "posting:default:sensitive" => false,
               "posting:default:language" => "zh",
               "reading:expand:media" => "default",
               "reading:expand:spoilers" => false
             } = json_response(conn, 200)
    end

    test "maps private platform visibility to client-compatible private visibility", %{conn: conn} do
      {:ok, user} =
        user_fixture()
        |> Accounts.update_user(%{default_post_visibility: "followers", locale: nil})

      conn =
        conn
        |> assign(:current_user, user)
        |> PreferenceController.show(%{})

      assert %{
               "posting:default:visibility" => "private",
               "posting:default:language" => "en"
             } = json_response(conn, 200)
    end
  end
end
