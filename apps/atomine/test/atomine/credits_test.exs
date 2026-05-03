defmodule Atomine.CreditsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Atomine.{CreditAccount, CreditLedgerEntry, Credits, CreditSpend}
  alias Elektrine.Repo

  describe "grant/5" do
    test "creates an account and records a positive ledger entry" do
      user = user_fixture()

      assert {:ok, ledger_entry} = Credits.grant(user.id, :dm_credit, 3, "verified_passkey")

      assert ledger_entry.amount == 3
      assert ledger_entry.reason == "verified_passkey"
      assert Credits.balance(user.id, :dm_credit) == 3

      account = Repo.get_by!(CreditAccount, user_id: user.id, credit_type: "dm_credit")
      assert account.balance == 3
      assert account.lifetime_earned == 3
      assert account.lifetime_spent == 0
    end
  end

  describe "spend/6" do
    test "debits the balance and records spend plus ledger rows" do
      user = user_fixture()
      assert {:ok, _} = Credits.grant(user.id, "dm_credit", 2, "test_grant")

      assert {:ok, spend} =
               Credits.spend(user.id, :dm_credit, 1, "first_dm", "user:#{user.id + 1}")

      assert spend.amount == 1
      assert spend.action == "first_dm"
      assert Credits.balance(user.id, :dm_credit) == 1

      assert Repo.aggregate(CreditSpend, :count) == 1

      assert [-1, 2] =
               CreditLedgerEntry
               |> order_by([e], desc: e.inserted_at, desc: e.id)
               |> select([e], e.amount)
               |> Repo.all()
    end

    test "rejects spends without enough credits" do
      user = user_fixture()

      assert {:error, :insufficient_credits} =
               Credits.spend(user.id, :dm_credit, 1, "first_dm", "user:999")

      assert Credits.balance(user.id, :dm_credit) == 0
      assert Repo.aggregate(CreditSpend, :count) == 0
    end

    test "idempotency key prevents duplicate debits" do
      user = user_fixture()
      assert {:ok, _} = Credits.grant(user.id, :dm_credit, 1, "test_grant")

      opts = [idempotency_key: "first_dm:#{user.id}:user:999"]

      assert {:ok, first_spend} =
               Credits.spend(user.id, :dm_credit, 1, "first_dm", "user:999", opts)

      assert {:ok, second_spend} =
               Credits.spend(user.id, :dm_credit, 1, "first_dm", "user:999", opts)

      assert second_spend.id == first_spend.id
      assert Credits.balance(user.id, :dm_credit) == 0
      assert Repo.aggregate(CreditSpend, :count) == 1
    end
  end

  describe "spend_action/6" do
    test "uses restricted credits before universal Atomine Credits" do
      user = user_fixture()
      assert {:ok, _} = Credits.grant(user.id, :dm_credit, 1, "restricted_grant")
      assert {:ok, _} = Credits.grant(user.id, :atomine_credit, 10, "universal_grant")

      assert {:ok, spend} =
               Credits.spend_action(user.id, :dm_credit, 3, "first_dm", "user:999")

      assert spend.credit_type == "dm_credit"
      assert spend.amount == 1
      assert Credits.balance(user.id, :dm_credit) == 0
      assert Credits.balance(user.id, :atomine_credit) == 10
    end

    test "falls back to universal Atomine Credits at the action price" do
      user = user_fixture()
      assert {:ok, _} = Credits.grant(user.id, :atomine_credit, 10, "universal_grant")

      assert {:ok, spend} =
               Credits.spend_action(user.id, :email_credit, 5, "send_email", "email:abc")

      assert spend.credit_type == "atomine_credit"
      assert spend.amount == 5
      assert Credits.balance(user.id, :email_credit) == 0
      assert Credits.balance(user.id, :atomine_credit) == 5
    end

    test "rejects action spends without restricted or universal credits" do
      user = user_fixture()

      assert {:error, :insufficient_credits} =
               Credits.spend_action(user.id, :email_credit, 5, "send_email", "email:abc")
    end
  end
end
