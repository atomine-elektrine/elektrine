defmodule ElektrineWeb.API.AccountBirthdayControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Profiles
  alias ElektrineWeb.API.AccountBirthdayController

  describe "index/2" do
    test "lists followed accounts with visible birthdays on the requested day", %{conn: conn} do
      viewer = user_fixture()

      visible =
        user_fixture(%{
          username: "birthdayvisible",
          birthday: ~D[2001-02-12],
          show_birthday: true
        })

      hidden =
        user_fixture(%{
          username: "birthdayhidden",
          birthday: ~D[2001-02-12],
          show_birthday: false
        })

      wrong_day =
        user_fixture(%{username: "birthdaywrong", birthday: ~D[2001-02-14], show_birthday: true})

      not_followed =
        user_fixture(%{
          username: "birthdaystranger",
          birthday: ~D[2001-02-12],
          show_birthday: true
        })

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, visible.id)
      assert {:ok, _follow} = Profiles.follow_user(viewer.id, hidden.id)
      assert {:ok, _follow} = Profiles.follow_user(viewer.id, wrong_day.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountBirthdayController.index(%{"day" => "12", "month" => "2"})

      assert [
               %{
                 "id" => id,
                 "username" => "birthdayvisible",
                 "pleroma" => %{"birthday" => "2001-02-12"}
               }
             ] =
               json_response(conn, 200)

      assert id == to_string(visible.id)
      refute id == to_string(not_followed.id)
    end

    test "returns 400 for invalid day or month", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountBirthdayController.index(%{"day" => "40", "month" => "2"})

      assert %{"error" => "invalid_day"} = json_response(conn, 400)
    end
  end
end
