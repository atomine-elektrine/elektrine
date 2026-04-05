defmodule ElektrineWeb.UserSettingsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias ElektrineWeb.UserAuth

  @avatar_fixture_path Path.expand(
                         "../../../../elektrine/priv/static/images/favicon-32x32.png",
                         __DIR__
                       )

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "settingsuser#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    %{user: user}
  end

  defp log_in_user(conn, user, opts \\ []) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)

    case Keyword.get(opts, :recent_auth_at) do
      recent_auth_at when is_integer(recent_auth_at) ->
        Plug.Conn.put_session(conn, UserAuth.recent_auth_session_key(), recent_auth_at)

      _ ->
        conn
    end
  end

  describe "avatar uploads" do
    test "keeps the selected avatar visible after auto-upload", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account")

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            last_modified: 1_594_171_879_000,
            name: "avatar-preview.png",
            content: File.read!(@avatar_fixture_path),
            type: "image/png"
          }
        ])

      html = render_upload(avatar, "avatar-preview.png")

      assert html =~ "avatar-preview.png"
      assert html =~ "Ready to save with your profile changes"
      assert has_element?(view, "#avatar-upload-status")
    end

    test "allows canceling a pending avatar selection", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account")

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            last_modified: 1_594_171_879_000,
            name: "avatar-preview.png",
            content: File.read!(@avatar_fixture_path),
            type: "image/png"
          }
        ])

      render_upload(avatar, "avatar-preview.png")

      view
      |> element("button", "Remove Selection")
      |> render_click()

      refute has_element?(view, "#avatar-upload-status")
      refute render(view) =~ "avatar-preview.png"
    end
  end

  describe "recovery email changes" do
    test "requires a recent login to change the recovery email", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account")

      html =
        view
        |> form("#profile-form",
          user: %{
            recovery_email: "attacker@example.com"
          }
        )
        |> render_submit()

      reloaded_user = Accounts.get_user!(user.id)

      assert html =~ "requires a recent login"
      assert reloaded_user.recovery_email in [nil, ""]
    end

    test "allows changing the recovery email after a recent login", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user, recent_auth_at: System.system_time(:second))
        |> live(~p"/account")

      html =
        view
        |> form("#profile-form",
          user: %{
            recovery_email: "fresh@example.com"
          }
        )
        |> render_submit()

      reloaded_user = Accounts.get_user!(user.id)

      assert html =~ "Please check your recovery email"
      assert reloaded_user.recovery_email == "fresh@example.com"
      refute reloaded_user.recovery_email_verified
    end
  end
end
