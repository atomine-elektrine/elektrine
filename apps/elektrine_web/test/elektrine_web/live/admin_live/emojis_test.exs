defmodule ElektrineWeb.AdminLive.EmojisTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo
  alias ElektrineWeb.AdminSecurity

  test "does not render legacy unsafe emoji image URLs", %{conn: conn} do
    insert_emoji!("badcat", "javascript:alert(1)")
    insert_emoji!("safe_cat", "https://cdn.example/emojis/safe-cat.png")

    admin = admin_user_fixture()

    {:ok, _view, html} =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> live(~p"/pripyat/emojis")

    assert html =~ ":badcat:"
    refute html =~ ~s|src="javascript:alert(1)"|
    assert html =~ ~s|src="https://cdn.example/emojis/safe-cat.png"|
  end

  defp insert_emoji!(shortcode, image_url) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {1, _} =
      Repo.insert_all(CustomEmoji, [
        %{
          shortcode: shortcode,
          image_url: image_url,
          instance_domain: nil,
          visible_in_picker: true,
          disabled: false,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn), do: Map.put(conn, :host, "example.com")

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> AdminSecurity.initialize_admin_session(user, auth_method: :passkey)
  end
end
