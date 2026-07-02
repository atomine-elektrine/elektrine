defmodule Elektrine.Accounts.DomainBlocksTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts

  describe "domain blocks" do
    test "blocks domains idempotently and lists normalized domains" do
      user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, " HTTPS://Example.COM/path ")
      assert {:ok, _block} = Accounts.block_domain(user.id, "example.com")
      assert Accounts.list_blocked_domains(user.id) == ["example.com"]
    end

    test "supports wildcard domain blocks" do
      user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, "*.Example.COM")
      assert Accounts.list_blocked_domains(user.id) == ["*.example.com"]
    end

    test "checks exact and wildcard domain block matches" do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, "example.com")
      assert {:ok, _block} = Accounts.block_domain(user.id, "*.blocked.example")

      assert Accounts.domain_blocked?(user.id, "example.com")
      assert Accounts.domain_blocked?(user.id, "News.Blocked.Example")
      refute Accounts.domain_blocked?(user.id, "safe.example")
      refute Accounts.domain_blocked?(other_user.id, "example.com")
    end

    test "rejects invalid domains" do
      user = user_fixture()

      assert {:error, :invalid_domain} = Accounts.block_domain(user.id, "localhost")
      assert {:error, :invalid_domain} = Accounts.block_domain(user.id, "bad domain.com")
    end

    test "unblocks domains idempotently" do
      user = user_fixture()

      assert {:ok, _block} = Accounts.block_domain(user.id, "example.com")
      assert {:ok, _deleted} = Accounts.unblock_domain(user.id, "example.com")
      assert {:ok, :not_blocked} = Accounts.unblock_domain(user.id, "example.com")
      assert Accounts.list_blocked_domains(user.id) == []
    end
  end
end
