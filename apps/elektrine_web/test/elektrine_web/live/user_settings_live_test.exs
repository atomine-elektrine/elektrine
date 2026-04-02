defmodule ElektrineWeb.UserSettingsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts

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

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
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
end
