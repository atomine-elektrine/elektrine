defmodule Elektrine.Repo.Migrations.HashRecoveryTokens do
  use Ecto.Migration
  import Ecto.Query

  defmodule MigrationUser do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}

    schema "users" do
      field(:password_reset_token, :string)
      field(:recovery_email_verification_token, :string)
    end
  end

  def up do
    repo()
    |> all_token_rows()
    |> Enum.each(fn user ->
      updates =
        %{}
        |> maybe_put_hashed_token(:password_reset_token, user.password_reset_token)
        |> maybe_put_hashed_token(
          :recovery_email_verification_token,
          user.recovery_email_verification_token
        )

      if updates != %{} do
        from(u in MigrationUser, where: u.id == ^user.id)
        |> repo().update_all(set: Map.to_list(updates))
      end
    end)
  end

  def down do
    raise Ecto.MigrationError, "HashRecoveryTokens is irreversible"
  end

  defp all_token_rows(repo) do
    repo.all(
      from(u in MigrationUser,
        where:
          not is_nil(u.password_reset_token) or not is_nil(u.recovery_email_verification_token),
        select: %{
          id: u.id,
          password_reset_token: u.password_reset_token,
          recovery_email_verification_token: u.recovery_email_verification_token
        }
      )
    )
  end

  defp maybe_put_hashed_token(updates, _field, nil), do: updates

  defp maybe_put_hashed_token(updates, field, value) when is_binary(value) do
    Map.put(updates, field, hash_token(value))
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
