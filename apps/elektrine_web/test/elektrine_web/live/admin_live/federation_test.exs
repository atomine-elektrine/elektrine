defmodule ElektrineWeb.AdminLive.FederationTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo
  alias ElektrineWeb.AdminLive.Federation
  alias ElektrineWeb.AdminSecurity

  test "mount loads federation stats without regclass encoding errors" do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: admin_user}}

    assert {:ok, mounted_socket} = Federation.mount(%{}, %{}, socket)

    assert is_map(mounted_socket.assigns.stats)
    assert mounted_socket.assigns.stats.total_actors >= 0
    assert mounted_socket.assigns.stats.total_activities >= 0
  end

  test "add_instance accepts checkbox on payloads for moderation booleans", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    conn =
      %{conn | host: "example.com"}

    {:ok, view, _html} =
      conn
      |> log_in_user(admin_user)
      |> live(~p"/pripyat/federation")

    _ = render_click(view, "show_add_block_modal")
    _ = render_click(view, "update_policy_form", %{"field" => "media_removal", "value" => "on"})
    _ = render_click(view, "update_policy_form", %{"field" => "media_nsfw", "value" => "on"})

    _ =
      render_click(view, "update_policy_form", %{
        "field" => "federated_timeline_removal",
        "value" => "on"
      })

    domain = "on-payload-#{System.unique_integer([:positive])}.example.com"

    _ =
      render_submit(view, "add_instance", %{
        "domain" => domain,
        "reason" => "test",
        "notes" => "test"
      })

    assert %Instance{} = instance = Repo.get_by(Instance, domain: domain)
    assert instance.media_removal
    assert instance.media_nsfw
    assert instance.federated_timeline_removal
  end

  test "add_instance form keeps typed fields when toggling a policy switch", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    conn =
      %{conn | host: "example.com"}

    {:ok, view, _html} =
      conn
      |> log_in_user(admin_user)
      |> live(~p"/pripyat/federation")

    _ = render_click(view, "show_add_block_modal")

    domain = "persist-#{System.unique_integer([:positive])}.example.com"
    reason = "Persist me"
    notes = "Keep these notes"

    _ =
      render_change(view, "sync_policy_form", %{
        "_target" => ["domain"],
        "domain" => domain,
        "reason" => reason,
        "notes" => notes
      })

    _ = render_click(view, "update_policy_form", %{"field" => "media_nsfw", "value" => "true"})

    assert view |> element("input[name=domain]") |> render() =~ ~s(value="#{domain}")
    assert view |> element("input[name=reason]") |> render() =~ ~s(value="#{reason}")
    assert view |> element("textarea[name=notes]") |> render() =~ notes
  end

  test "update_policy_form handles toggle clicks without explicit value payload", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    conn =
      %{conn | host: "example.com"}

    {:ok, view, _html} =
      conn
      |> log_in_user(admin_user)
      |> live(~p"/pripyat/federation")

    _ = render_click(view, "show_add_block_modal")

    _ = render_click(view, "update_policy_form", %{"field" => "followers_only"})
    assert view |> element("input[phx-value-field=followers_only]") |> render() =~ ~s(checked)

    _ = render_click(view, "update_policy_form", %{"field" => "followers_only"})
    refute view |> element("input[phx-value-field=followers_only]") |> render() =~ ~s(checked)
  end

  test "expired elevation redirects back to the requested live admin page", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    assert {:error, {:redirect, %{to: redirect_to}}} =
             conn
             |> Map.put(:host, "example.com")
             |> log_in_user(admin_user)
             |> Plug.Conn.put_session(:admin_elevated_until, System.system_time(:second) - 1)
             |> live(~p"/pripyat/federation")

    assert redirect_to == "/pripyat/security/elevate?return_to=%2Fpripyat%2Ffederation"
  end

  test "accepts equivalent loopback addresses for live admin elevation", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    assert {:ok, _view, _html} =
             conn
             |> Map.put(:host, "example.com")
             |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
             |> log_in_user(admin_user)
             |> live(~p"/pripyat/federation")
  end

  defp log_in_user(conn, user) do
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
