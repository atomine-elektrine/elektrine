defmodule Elektrine.Repo.Migrations.HashEmailUnsubscribeTokens do
  use Ecto.Migration

  import Ecto.Query

  defmodule EmailUnsubscribe do
    use Ecto.Schema

    schema "email_unsubscribes" do
      field(:token, :string)
    end
  end

  def up do
    repo().transaction(fn ->
      EmailUnsubscribe
      |> repo().all()
      |> Enum.each(fn unsubscribe ->
        token = unsubscribe.token

        if is_binary(token) and not hashed_token?(token) do
          repo().update_all(
            from(u in EmailUnsubscribe, where: u.id == ^unsubscribe.id),
            set: [token: hash_token(token)]
          )
        end
      end)
    end)
  end

  def down do
    :ok
  end

  defp hash_token(token) when is_binary(token) do
    token
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp hashed_token?(token) do
    Regex.match?(~r/^[0-9a-f]{64}$/, token)
  end
end
