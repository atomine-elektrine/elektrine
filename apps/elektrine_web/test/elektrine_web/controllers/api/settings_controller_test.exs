defmodule ElektrineWeb.API.SettingsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Accounts.ClientAppSettings
  alias ElektrineWeb.Plugs.APIAuth

  import Elektrine.AccountsFixtures

  describe "notification settings" do
    test "updates native notification fields", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/settings/notifications", %{
          "notify_on_mention" => false,
          "notify_on_reply" => false,
          "notify_on_like" => false
        })

      assert %{
               "status" => "success",
               "settings" => %{
                 "notify_on_mention" => false,
                 "notify_on_reply" => false,
                 "notify_on_like" => false
               }
             } = json_response(conn, 200)

      user = Accounts.get_user!(user.id)
      assert user.notify_on_mention == false
      assert user.notify_on_reply == false
      assert user.notify_on_like == false
    end

    test "updates notification aliases through prefixed route", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/pleroma/notification_settings", %{
          "notify_on_follow" => "false",
          "notify_on_message" => "false",
          "block_from_strangers" => "true",
          "hide_notification_contents" => "true"
        })

      assert %{
               "status" => "success",
               "settings" => %{
                 "notify_on_new_follower" => false,
                 "notify_on_direct_message" => false,
                 "block_notifications_from_strangers" => true,
                 "block_from_strangers" => true,
                 "hide_notification_contents" => true
               }
             } = json_response(conn, 200)

      user = Accounts.get_user!(user.id)
      assert user.notify_on_new_follower == false
      assert user.notify_on_direct_message == false
      assert user.block_notifications_from_strangers == true
      assert user.hide_notification_contents == true
    end
  end

  describe "password settings" do
    test "changes password through prefixed route", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/change_password", %{
          "password" => valid_user_password(),
          "new_password" => "new valid password 123",
          "new_password_confirmation" => "new valid password 123"
        })

      assert %{"message" => "Password updated successfully"} = json_response(conn, 200)

      user = Accounts.get_user!(user.id)
      assert Argon2.verify_pass("new valid password 123", user.password_hash)
    end

    test "rejects mismatched password confirmation through prefixed route", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/change_password", %{
          "password" => valid_user_password(),
          "new_password" => "new valid password 123",
          "new_password_confirmation" => "different valid password 123"
        })

      assert %{"error" => "Failed to update password", "errors" => errors} =
               json_response(conn, 422)

      assert %{"password_confirmation" => [_ | _]} = errors
    end
  end

  describe "email settings" do
    test "changes recovery email through prefixed route", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/change_email", %{
          "password" => valid_user_password(),
          "email" => "new-recovery@example.com"
        })

      assert %{
               "status" => "success",
               "email" => "new-recovery@example.com",
               "verified" => false
             } = json_response(conn, 200)

      user = Accounts.get_user!(user.id)
      assert user.recovery_email == "new-recovery@example.com"
      assert user.recovery_email_verified == false
    end

    test "rejects email change with bad password", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/change_email", %{
          "password" => "wrong password",
          "email" => "new-recovery@example.com"
        })

      assert %{"error" => "Password is incorrect"} = json_response(conn, 401)

      user = Accounts.get_user!(user.id)
      refute user.recovery_email == "new-recovery@example.com"
    end

    test "rejects invalid recovery email through prefixed route", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/pleroma/change_email", %{
          "password" => valid_user_password(),
          "email" => "not-an-email"
        })

      assert %{"error" => "Failed to update email", "errors" => errors} =
               json_response(conn, 422)

      assert %{"recovery_email" => [_ | _]} = errors
    end
  end

  describe "client app settings" do
    test "returns an empty map when no settings are stored", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/pleroma/settings/elktest")

      assert %{} = json_response(conn, 200)
    end

    test "merges updates and deletes nil keys", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      {:ok, _settings} =
        ClientAppSettings.update_settings(user.id, "elktest", %{
          "theme" => "dark",
          "layout" => %{"density" => "compact", "columns" => 3},
          "stale" => true
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> patch("/api/v1/pleroma/settings/elktest", %{
          "theme" => "light",
          "layout" => %{"columns" => nil, "font" => "system"},
          "stale" => nil
        })

      assert %{
               "theme" => "light",
               "layout" => %{"density" => "compact", "font" => "system"}
             } = json_response(conn, 200)

      refute Map.has_key?(json_response(conn, 200), "stale")

      assert %{
               "theme" => "light",
               "layout" => %{"density" => "compact", "font" => "system"}
             } = ClientAppSettings.get_settings(user.id, "elktest")
    end

    test "rejects invalid app names", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> patch("/api/v1/pleroma/settings/bad app", %{"enabled" => true})

      assert %{
               "error" => "invalid_app_settings",
               "details" => %{"app" => [_ | _]}
             } = json_response(conn, 422)
    end
  end
end
