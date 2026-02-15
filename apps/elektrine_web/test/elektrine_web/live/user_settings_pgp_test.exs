defmodule ElektrineWeb.UserSettingsPGPTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.Repo

  @sample_pgp_key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mQENBGaT5OUBCAC3qKXrCXvWl5vNlRBNKPZNFAj3zLjXBdgOJvSqHHJwlHIbN1Gs
  NG9BF8VCGU3JNqjKoTcTkXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJj
  HJkHAJqG8TLSB9c1rF9TqFcPjXvR9mRvRhFLK6bFtF1aF4G5UJUBL6UM5qF8VCGU
  3JNqjKoTcTkXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJjHJkHAJqG8T
  LSB9c1rF9TqFcPjXvR9mRvRhFLK6bFtF1aF4G5UJUBL6UM5qF8VCGU3JNqjKoTcT
  kXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJjHJkHAJqG8TLSB9c1rF9T
  qFcPjXvRABEBAAG0GlRlc3QgVXNlciA8dGVzdEBleGFtcGxlLmNvbT6JATgEEwEI
  ACIFAmaT5OUCGwMGCwkIBwMCBhUIAgkKCwQWAgMBAh4BAheAAAoJEJQa5lST5OXv
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
  =ABCD
  -----END PGP PUBLIC KEY BLOCK-----
  """

  setup do
    # Create a test user
    {:ok, user} =
      Accounts.create_user(%{
        username: "pgpsettingsuser#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    %{user: user}
  end

  # Helper to log in a user for LiveView tests
  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  describe "helper functions" do
    test "format_fingerprint formats with spaces" do
      formatted = ElektrineWeb.UserSettingsLive.format_fingerprint("ABCD1234EFGH5678")
      assert formatted == "ABCD 1234 EFGH 5678"
    end

    test "format_fingerprint handles nil" do
      formatted = ElektrineWeb.UserSettingsLive.format_fingerprint(nil)
      assert formatted == ""
    end

    test "wkd_hash generates valid hash" do
      hash = ElektrineWeb.UserSettingsLive.wkd_hash("testuser")
      assert is_binary(hash)
      assert String.length(hash) > 0
    end
  end

  describe "PGP settings display" do
    test "shows upload form when user has no PGP key", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Should show the upload form
      assert has_element?(view, "textarea[name='pgp_public_key']")
      assert has_element?(view, "button", "Upload Public Key")
    end

    test "shows key info when user has PGP key", %{conn: conn, user: user} do
      # Set a PGP key for the user
      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: @sample_pgp_key,
        pgp_fingerprint: "ABCD1234EFGH5678IJKL9012MNOP3456QRST7890",
        pgp_key_id: "QRST7890",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Should show key info, not upload form
      assert has_element?(view, "span", "PGP Key Active")
      assert has_element?(view, "button", "Remove PGP Key")
      refute has_element?(view, "textarea[name='pgp_public_key']")
    end

    test "shows formatted fingerprint", %{conn: conn, user: user} do
      fingerprint = "ABCD1234EFGH5678IJKL9012MNOP3456QRST7890"

      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: @sample_pgp_key,
        pgp_fingerprint: fingerprint,
        pgp_key_id: "QRST7890",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {:ok, _view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Fingerprint should be formatted with spaces (groups of 4)
      assert html =~ "ABCD 1234 EFGH 5678"
    end

    test "shows WKD discovery URL", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: @sample_pgp_key,
        pgp_fingerprint: "ABCD1234",
        pgp_key_id: "1234",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {:ok, _view, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Should show WKD URL
      assert html =~ "/.well-known/openpgpkey/hu/"
    end
  end

  describe "upload_pgp_key event" do
    test "shows error for invalid key format", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Try to upload invalid key
      view
      |> form("#pgp-key-form", %{pgp_public_key: "not a valid key"})
      |> render_submit()

      # Form should still be visible (key was not stored)
      assert has_element?(view, "textarea[name='pgp_public_key']")
      refute has_element?(view, "span", "PGP Key Active")
    end

    test "shows error for empty key", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Try to upload empty key - form validation should prevent this
      # but server should handle it too
      view
      |> form("#pgp-key-form", %{pgp_public_key: ""})
      |> render_submit()

      # Form should still be visible (submission blocked or error shown)
      assert has_element?(view, "textarea[name='pgp_public_key']")
    end
  end

  describe "delete_pgp_key event" do
    test "removes PGP key from user", %{conn: conn, user: user} do
      # First add a key
      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: @sample_pgp_key,
        pgp_fingerprint: "ABCD1234",
        pgp_key_id: "1234",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      # Verify key is shown
      assert has_element?(view, "span", "PGP Key Active")

      # Click delete button
      view
      |> element("button", "Remove PGP Key")
      |> render_click()

      # Should now show upload form
      assert has_element?(view, "textarea[name='pgp_public_key']")
      refute has_element?(view, "span", "PGP Key Active")
    end

    test "verifies key is removed from database after deletion", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: @sample_pgp_key,
        pgp_fingerprint: "ABCD1234",
        pgp_key_id: "1234",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account?tab=email")

      view
      |> element("button", "Remove PGP Key")
      |> render_click()

      # Verify the key is actually removed from the database
      updated_user = Repo.get!(Elektrine.Accounts.User, user.id)
      assert updated_user.pgp_public_key == nil
      assert updated_user.pgp_fingerprint == nil
      assert updated_user.pgp_key_id == nil
    end
  end

  describe "email tab navigation" do
    test "can navigate to email tab with PGP section", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account")

      # Click on email tab
      view
      |> element("a[phx-value-tab='email']")
      |> render_click()

      # Should show PGP section
      assert render(view) =~ "PGP Encryption"
    end
  end

  describe "PubSub message handling" do
    test "ignores storage updates without crashing", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/account")

      send(view.pid, {:storage_updated, %{user_id: user.id, storage_used_bytes: 123}})

      assert render(view) =~ "Account Settings"
    end
  end
end
