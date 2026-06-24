defmodule Elektrine.Repo.Migrations.HashAndEncryptShareTokens do
  use Ecto.Migration

  import Ecto.Query

  alias Elektrine.Secrets.EncryptedString

  defmodule DriveShare do
    use Ecto.Schema

    schema "drive_shares" do
      field(:token, :string)
      field(:token_hash, :string)
    end
  end

  defmodule NoteShare do
    use Ecto.Schema

    schema "note_shares" do
      field(:token, :string)
      field(:token_hash, :string)
    end
  end

  def up do
    alter table(:drive_shares) do
      add(:token_hash, :string)
    end

    alter table(:note_shares) do
      add(:token_hash, :string)
    end

    flush()

    backfill_share_tokens(DriveShare)
    backfill_share_tokens(NoteShare)

    alter table(:drive_shares) do
      modify(:token_hash, :string, null: false)
    end

    alter table(:note_shares) do
      modify(:token_hash, :string, null: false)
    end

    create(unique_index(:drive_shares, [:token_hash]))
    create(unique_index(:note_shares, [:token_hash]))
  end

  def down do
    drop_if_exists(unique_index(:note_shares, [:token_hash]))
    drop_if_exists(unique_index(:drive_shares, [:token_hash]))

    restore_share_tokens(NoteShare)
    restore_share_tokens(DriveShare)

    alter table(:note_shares) do
      remove(:token_hash)
    end

    alter table(:drive_shares) do
      remove(:token_hash)
    end
  end

  defp backfill_share_tokens(schema) do
    repo().transaction(fn ->
      schema
      |> repo().all()
      |> Enum.each(fn share ->
        token = plaintext_token!(share.token)

        repo().update_all(
          from(s in schema, where: s.id == ^share.id),
          set: [token: encrypted_token!(token), token_hash: hash_token(token)]
        )
      end)
    end)
  end

  defp restore_share_tokens(schema) do
    repo().transaction(fn ->
      schema
      |> repo().all()
      |> Enum.each(fn share ->
        repo().update_all(
          from(s in schema, where: s.id == ^share.id),
          set: [token: plaintext_token!(share.token)]
        )
      end)
    end)
  end

  defp plaintext_token!(token) when is_binary(token) do
    case EncryptedString.decrypt(token) do
      {:ok, plaintext} -> plaintext
      :error -> token
    end
  end

  defp plaintext_token!(_token), do: raise("share token is missing")

  defp encrypted_token!(token) do
    if EncryptedString.encrypted?(token) do
      token
    else
      case EncryptedString.encrypt(token) do
        {:ok, encrypted} -> encrypted
        :error -> raise("could not encrypt share token")
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
