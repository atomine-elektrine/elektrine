defmodule ElektrineWeb.API.DomainBlockControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias ElektrineWeb.API.DomainBlockController

  import Elektrine.AccountsFixtures

  describe "index/2" do
    test "lists blocked domains for the current user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, "example.com")
      assert {:ok, _block} = Accounts.block_domain(other_user.id, "other.example")

      conn =
        conn
        |> assign(:current_user, user)
        |> DomainBlockController.index(%{})

      assert ["example.com"] = json_response(conn, 200)
    end
  end

  describe "create/2" do
    test "blocks a normalized domain", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> DomainBlockController.create(%{"domain" => "https://Example.COM/profile"})

      assert %{} = json_response(conn, 200)
      assert Accounts.list_blocked_domains(user.id) == ["example.com"]
    end

    test "rejects invalid domains", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> DomainBlockController.create(%{"domain" => "bad domain"})

      assert %{"error" => "invalid domain"} = json_response(conn, 422)
    end
  end

  describe "delete/2" do
    test "unblocks a domain", %{conn: conn} do
      user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, "example.com")

      conn =
        conn
        |> assign(:current_user, user)
        |> DomainBlockController.delete(%{"domain" => "example.com"})

      assert %{} = json_response(conn, 200)
      assert Accounts.list_blocked_domains(user.id) == []
    end
  end
end
