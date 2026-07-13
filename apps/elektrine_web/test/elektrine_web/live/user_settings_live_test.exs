defmodule ElektrineWeb.UserSettingsLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.Developer
  alias Elektrine.Developer.Webhook
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

  describe "theme preferences" do
    test "persists and immediately applies a saved custom theme", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=preferences")

      # Picking custom mode reveals the palette editor.
      view
      |> form("#preferences-form", user: %{theme_mode: "custom"})
      |> render_change()

      view
      |> form("#preferences-form",
        user: %{
          theme_mode: "custom",
          theme_overrides: %{
            color_base_100: "#101820",
            color_primary: "#f5d90a"
          }
        }
      )
      |> render_submit()

      assert_push_event(view, "apply-theme-settings", payload)
      assert payload.mode == "custom"
      assert payload.theme == "dark"
      assert payload.style =~ "--theme-override-color-base-100: #101820"
      assert payload.style =~ "--theme-override-color-primary: #f5d90a"

      reloaded_user = Accounts.get_user!(user.id)
      assert reloaded_user.theme_mode == "custom"

      assert Map.take(reloaded_user.theme_overrides, [
               "color_base_100",
               "color_primary"
             ]) == %{
               "color_base_100" => "#101820",
               "color_primary" => "#f5d90a"
             }
    end

    test "pinning day mode deactivates but keeps the custom palette", %{conn: conn, user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          "theme_mode" => "custom",
          "theme_overrides" => %{"color_base_100" => "#101820"}
        })

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=preferences")

      # Clicking a mode radio hides the palette editor before the save.
      view
      |> form("#preferences-form", user: %{theme_mode: "light"})
      |> render_change()

      view
      |> form("#preferences-form", user: %{theme_mode: "light"})
      |> render_submit()

      assert_push_event(view, "apply-theme-settings", %{mode: "light", theme: "light", style: ""})

      reloaded_user = Accounts.get_user!(user.id)
      assert reloaded_user.theme_mode == "light"
      assert reloaded_user.theme_overrides == %{"color_base_100" => "#101820"}
    end

    test "immediately clears active overrides when resetting the theme", %{conn: conn, user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          "theme_mode" => "custom",
          "theme_overrides" => %{"color_base_100" => "#101820"}
        })

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=preferences")

      view
      |> form("#preferences-form", user: %{})
      |> render_submit(%{"action" => "reset_theme_defaults"})

      assert_push_event(view, "apply-theme-settings", %{
        mode: "custom",
        theme: "light",
        style: style
      })

      assert style =~ "--theme-override-color-base-100: #f5f7fa"
      assert Accounts.get_user!(user.id).theme_overrides == %{}
    end
  end

  describe "encryption coverage" do
    test "shows optional chat E2EE and server-side encrypted-at-rest coverage", %{
      conn: conn,
      user: user
    } do
      {:ok, _view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=security")

      assert html =~ "Encryption Coverage"
      assert html =~ "Encrypted at rest?"
      assert html =~ "Chat messages"
      assert html =~ "Optional"
      assert html =~ "Depends"
      assert html =~ "Available now"
      assert html =~ "Chat messages are encrypted at rest by default"
      refute html =~ "Regular notes"
    end
  end

  describe "developer webhooks" do
    test "shows MCP setup guidance on the developer tab", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=developer")

      html = render(view)

      assert html =~ "MCP for AI Clients"
      assert html =~ "/api/ext/v1/mcp"
      assert html =~ "ekt_your_token_here"
      assert html =~ "tools/list"
      assert html =~ "read:kairo"
    end

    test "lists every API family in the API reference on the developer tab", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=developer")

      html = render(view)

      assert html =~ "POST /email/messages"
      assert html =~ "POST /proofs"
      assert html =~ "POST /static-site/deploy"
      assert html =~ "DELETE /dns/zones/:zone_id/records/:id"
      assert html =~ "POST /kairo/sources/:id/retry"
      assert html =~ "PUT /nerve/entries/:id"
      assert html =~ "POST /webhooks/:id/rotate-secret"
      # The nerve-wide delete endpoint does not exist; only entries are deletable.
      refute html =~ "DELETE /api/ext/v1/nerve<"
    end

    test "shows webhook secret fingerprints without exposing stored secrets", %{
      conn: conn,
      user: user
    } do
      {:ok, webhook} =
        Developer.create_webhook(user.id, %{
          name: "Settings Hook",
          url: "https://example.com/webhook",
          events: ["post.created"]
        })

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=developer")

      html = render(view)

      assert html =~ "Settings Hook"
      assert html =~ Webhook.secret_fingerprint(webhook)
      refute html =~ webhook.secret
      refute html =~ String.slice(webhook.secret, 0, 8) <> "..."
    end
  end

  describe "RSS settings" do
    test "uses the shared app navigation", %{conn: conn, user: user} do
      {:ok, _view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/settings/rss")

      assert html =~ "RSS Feeds"
      assert html =~ ~s(data-test="global-composer")
    end

    test "typing a feed URL updates the form without crashing", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/settings/rss")

      html =
        render_change(view, "update_url", %{
          "_target" => ["url"],
          "url" => "https://feeds.arstechnica.com/arstechnica/index"
        })

      assert html =~ "https://feeds.arstechnica.com/arstechnica/index"
    end

    test "forged feed events with malformed ids do not crash", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/settings/rss")

      assert render_hook(view, "remove_feed", %{"feed_id" => "12abc"}) =~ "Failed to unsubscribe"
      assert render_hook(view, "toggle_timeline", %{"subscription_id" => "12abc"}) =~ "RSS Feeds"
    end
  end
end
