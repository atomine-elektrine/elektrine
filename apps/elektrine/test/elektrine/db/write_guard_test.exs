defmodule Elektrine.DB.WriteGuardTest do
  use Elektrine.DataCase, async: false

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.User
  alias Elektrine.DB.WriteGuard
  alias Elektrine.Repo

  test "runs writes normally when transaction is writable" do
    user = user_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      WriteGuard.run("test write", fn ->
        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(set: [last_imap_access: now])
      end)

    assert {1, _} = result
    assert Repo.get!(User, user.id).last_imap_access == now
  end

  test "returns fallback when transaction is read-only" do
    user = user_fixture()

    assert {:ok, {:error, :read_only_sql_transaction}} =
             Repo.transaction(fn ->
               Repo.query!("SET TRANSACTION READ ONLY")

               WriteGuard.run("test read-only write", fn ->
                 from(u in User, where: u.id == ^user.id)
                 |> Repo.update_all(set: [last_imap_access: DateTime.utc_now()])
               end)
             end)

    assert is_nil(Repo.get!(User, user.id).last_imap_access)
  end

  test "supports custom fallback values in read-only transactions" do
    user = user_fixture()

    assert {:ok, {:ok, :skipped}} =
             Repo.transaction(fn ->
               Repo.query!("SET TRANSACTION READ ONLY")

               WriteGuard.run(
                 "test custom read-only fallback",
                 fn ->
                   from(u in User, where: u.id == ^user.id)
                   |> Repo.update_all(set: [last_imap_access: DateTime.utc_now()])
                 end,
                 on_read_only: {:ok, :skipped}
               )
             end)

    assert is_nil(Repo.get!(User, user.id).last_imap_access)
  end
end
