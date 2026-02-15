defmodule ElektrineWeb.Plugs.CustomDomainTest do
  use ElektrineWeb.ConnCase, async: true

  alias ElektrineWeb.Plugs.CustomDomain, as: CustomDomainPlug
  alias Elektrine.AccountsFixtures

  describe "call/2" do
    test "passes through for elektrine.com" do
      conn =
        build_conn()
        |> Map.put(:host, "elektrine.com")
        |> CustomDomainPlug.call([])

      refute conn.halted
      refute conn.assigns[:custom_domain]
    end

    test "passes through for www.elektrine.com" do
      conn =
        build_conn()
        |> Map.put(:host, "www.elektrine.com")
        |> CustomDomainPlug.call([])

      refute conn.halted
      refute conn.assigns[:custom_domain]
    end

    test "passes through for z.org" do
      conn =
        build_conn()
        |> Map.put(:host, "z.org")
        |> CustomDomainPlug.call([])

      refute conn.halted
      refute conn.assigns[:custom_domain]
    end

    test "passes through for z.org subdomains" do
      conn =
        build_conn()
        |> Map.put(:host, "username.z.org")
        |> CustomDomainPlug.call([])

      refute conn.halted
      # Subdomain handling is done by ProfileSubdomain plug
      refute conn.assigns[:custom_domain]
    end

    test "passes through for fly.dev domains" do
      conn =
        build_conn()
        |> Map.put(:host, "elektrine.fly.dev")
        |> CustomDomainPlug.call([])

      refute conn.halted
      refute conn.assigns[:custom_domain]
    end

    test "passes through for localhost" do
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> CustomDomainPlug.call([])

      refute conn.halted
      refute conn.assigns[:custom_domain]
    end

    test "returns 404 for unregistered custom domain" do
      conn =
        build_conn()
        |> Map.put(:host, "unregistered-domain.com")
        |> CustomDomainPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "returns 503 for pending custom domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, _domain} = Elektrine.CustomDomains.add_domain(user.id, "pending-custom.com")

      conn =
        build_conn()
        |> Map.put(:host, "pending-custom.com")
        |> CustomDomainPlug.call([])

      assert conn.halted
      assert conn.status == 503
    end

    test "sets assigns for active custom domain" do
      user = AccountsFixtures.user_fixture()
      {:ok, domain} = Elektrine.CustomDomains.add_domain(user.id, "active-custom.com")

      # Activate the domain
      {:ok, _} =
        domain
        |> Ecto.Changeset.change(%{status: "active", ssl_status: "issued"})
        |> Elektrine.Repo.update()

      conn =
        build_conn()
        |> Map.put(:host, "active-custom.com")
        |> CustomDomainPlug.call([])

      refute conn.halted
      assert conn.assigns[:custom_domain] == "active-custom.com"
      assert conn.assigns[:subdomain_handle] == user.handle
      assert conn.assigns[:custom_domain_user].id == user.id
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      opts = [some: :option]
      assert CustomDomainPlug.init(opts) == opts
    end
  end
end
