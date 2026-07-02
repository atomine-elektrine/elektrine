defmodule ElektrineWeb.API.PushSubscriptionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Push
  alias ElektrineWeb.API.PushSubscriptionController

  describe "push subscription endpoints" do
    test "creates and reads a web push subscription", %{conn: conn} do
      user = user_fixture()

      create_conn =
        conn
        |> assign(:current_user, user)
        |> PushSubscriptionController.create(web_subscription_params("https://push.example/a"))

      assert %{
               "id" => id,
               "endpoint" => "https://push.example/a",
               "alerts" => %{"mention" => true},
               "policy" => "followed",
               "server_key" => nil
             } = json_response(create_conn, 201)

      show_conn =
        build_conn()
        |> assign(:current_user, user)
        |> PushSubscriptionController.show(%{})

      assert %{"id" => ^id, "endpoint" => "https://push.example/a"} =
               json_response(show_conn, 200)
    end

    test "updates and deletes the current subscription", %{conn: conn} do
      user = user_fixture()

      assert {:ok, _subscription} =
               Push.upsert_web_subscription(
                 user.id,
                 web_subscription_params("https://push.example/update")
               )

      update_conn =
        conn
        |> assign(:current_user, user)
        |> PushSubscriptionController.update(%{
          "data" => %{"alerts" => %{"follow" => false}, "policy" => "none"}
        })

      assert %{"alerts" => %{"follow" => false}, "policy" => "none"} =
               json_response(update_conn, 200)

      delete_conn =
        build_conn()
        |> assign(:current_user, user)
        |> PushSubscriptionController.delete(%{})

      assert %{} = json_response(delete_conn, 200)
      refute Push.get_web_subscription(user.id)
    end

    test "returns 404 when no current subscription exists", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> PushSubscriptionController.show(%{})

      assert %{"error" => "subscription not found"} = json_response(conn, 404)
    end
  end

  defp web_subscription_params(endpoint) do
    %{
      "subscription" => %{
        "endpoint" => endpoint,
        "keys" => %{
          "p256dh" => "public-key",
          "auth" => "auth-secret"
        }
      },
      "data" => %{
        "alerts" => %{"mention" => true},
        "policy" => "followed"
      }
    }
  end
end
