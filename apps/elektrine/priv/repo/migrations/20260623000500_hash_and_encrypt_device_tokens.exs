defmodule Elektrine.Repo.Migrations.HashAndEncryptDeviceTokens do
  use Ecto.Migration

  import Ecto.Query

  alias Elektrine.Secrets.EncryptedString

  defmodule DeviceToken do
    use Ecto.Schema

    schema "device_tokens" do
      field(:token, :string)
      field(:token_hash, :string)
    end
  end

  def up do
    alter table(:device_tokens) do
      add(:token_hash, :string)
    end

    flush()

    repo().transaction(fn ->
      DeviceToken
      |> repo().all()
      |> Enum.each(fn device ->
        token = plaintext_token!(device.token)

        repo().update_all(
          from(d in DeviceToken, where: d.id == ^device.id),
          set: [token: encrypted_token!(token), token_hash: hash_token(token)]
        )
      end)
    end)

    alter table(:device_tokens) do
      modify(:token_hash, :string, null: false)
    end

    create(unique_index(:device_tokens, [:token_hash]))
  end

  def down do
    drop_if_exists(unique_index(:device_tokens, [:token_hash]))

    repo().transaction(fn ->
      DeviceToken
      |> repo().all()
      |> Enum.each(fn device ->
        repo().update_all(
          from(d in DeviceToken, where: d.id == ^device.id),
          set: [token: plaintext_token!(device.token)]
        )
      end)
    end)

    alter table(:device_tokens) do
      remove(:token_hash)
    end
  end

  defp plaintext_token!(token) when is_binary(token) do
    case EncryptedString.decrypt(token) do
      {:ok, plaintext} -> plaintext
      :error -> token
    end
  end

  defp plaintext_token!(_token), do: raise("device token is missing")

  defp encrypted_token!(token) do
    if EncryptedString.encrypted?(token) do
      token
    else
      case EncryptedString.encrypt(token) do
        {:ok, encrypted} -> encrypted
        :error -> raise("could not encrypt device token")
      end
    end
  end

  defp hash_token(token) when is_binary(token) do
    token
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
