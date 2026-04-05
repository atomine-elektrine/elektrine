defmodule ElektrineEmailWeb.Admin.CustomDomainsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.{Accounts, Repo}
  alias Elektrine.AccountsFixtures
  alias Elektrine.Email

  describe "GET /pripyat/custom-domains" do
    test "renders the custom domain console with search and status filters", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      owner = AccountsFixtures.user_fixture(%{username: "domainowner"})
      other_owner = AccountsFixtures.user_fixture(%{username: "pendingowner"})

      {:ok, verified_domain} =
        Email.create_custom_domain(owner, %{"domain" => "mail.inspectable.test"})

      verified_domain =
        verified_domain
        |> Ecto.Changeset.change(%{
          status: "verified",
          verified_at: now(),
          dkim_synced_at: now()
        })
        |> Repo.update!()

      owner
      |> Ecto.Changeset.change(preferred_email_domain: verified_domain.domain)
      |> Repo.update!()

      {:ok, pending_domain} =
        Email.create_custom_domain(other_owner, %{"domain" => "mail.needsreview.test"})

      pending_domain
      |> Ecto.Changeset.change(last_error: "Verification TXT record not found")
      |> Repo.update!()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/custom-domains?status=verified&search=inspectable")

      html = html_response(conn, 200)

      assert html =~ "Custom Domains"
      assert html =~ verified_domain.domain
      assert html =~ owner.username
      assert html =~ "Primary Sending Domain"
      refute html =~ pending_domain.domain
      refute html =~ other_owner.username
    end
  end

  describe "GET /pripyat" do
    test "shows custom domain overview and recent domains on the dashboard", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      owner = AccountsFixtures.user_fixture(%{username: "dashboarddomain"})

      {:ok, custom_domain} =
        Email.create_custom_domain(owner, %{"domain" => "mail.dashboardsignal.test"})

      custom_domain
      |> Ecto.Changeset.change(%{
        status: "verified",
        verified_at: now(),
        dkim_synced_at: now()
      })
      |> Repo.update!()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat")

      html = html_response(conn, 200)

      assert html =~ "Domain Health"
      assert html =~ "Recent Domains"
      assert html =~ custom_domain.domain
      assert html =~ owner.username
    end
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp make_admin(user) do
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
