defmodule Elektrine.Repo.Migrations.HashOauthSecretsAndTokens do
  use Ecto.Migration

  import Ecto.Query

  defmodule OAuthApp do
    use Ecto.Schema

    schema "oauth_apps" do
      field(:client_secret, :string)
    end
  end

  defmodule OAuthToken do
    use Ecto.Schema

    schema "oauth_tokens" do
      field(:token, :string)
      field(:refresh_token, :string)
    end
  end

  defmodule OAuthAuthorization do
    use Ecto.Schema

    schema "oauth_authorizations" do
      field(:token, :string)
    end
  end

  def up do
    flush()

    repo().transaction(fn ->
      repo().all(OAuthApp)
      |> Enum.each(fn app ->
        repo().update_all(
          from(a in OAuthApp, where: a.id == ^app.id),
          set: [client_secret: hash_secret(app.client_secret)]
        )
      end)

      repo().all(OAuthToken)
      |> Enum.each(fn token ->
        repo().update_all(
          from(t in OAuthToken, where: t.id == ^token.id),
          set: [token: hash_secret(token.token), refresh_token: hash_secret(token.refresh_token)]
        )
      end)

      repo().all(OAuthAuthorization)
      |> Enum.each(fn authorization ->
        repo().update_all(
          from(a in OAuthAuthorization, where: a.id == ^authorization.id),
          set: [token: hash_secret(authorization.token)]
        )
      end)
    end)
  end

  def down, do: :ok

  defp hash_secret(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp hash_secret(_), do: nil
end
