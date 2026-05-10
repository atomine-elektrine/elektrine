defmodule Elektrine.Repo.Migrations.EncryptNotesContent do
  use Ecto.Migration

  import Ecto.Query

  alias Elektrine.Secrets.EncryptedString

  defmodule Note do
    use Ecto.Schema

    schema "notes" do
      field(:title, :string)
      field(:body, :string)
    end
  end

  def up do
    alter table(:notes) do
      modify :title, :text
    end

    flush()

    repo().transaction(fn ->
      repo().all(Note)
      |> Enum.each(fn note ->
        repo().update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [title: encrypt_note_value(note.title), body: encrypt_note_value(note.body)]
        )
      end)
    end)
  end

  def down do
    repo().transaction(fn ->
      repo().all(Note)
      |> Enum.each(fn note ->
        repo().update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [title: decrypt_note_value(note.title), body: decrypt_note_value(note.body)]
        )
      end)
    end)

    alter table(:notes) do
      modify :title, :string
    end
  end

  defp encrypt_note_value(nil), do: nil

  defp encrypt_note_value(value) when is_binary(value) do
    if EncryptedString.encrypted?(value) do
      value
    else
      case EncryptedString.encrypt(value) do
        {:ok, encrypted} -> encrypted
        :error -> raise "could not encrypt note content"
      end
    end
  end

  defp decrypt_note_value(nil), do: nil

  defp decrypt_note_value(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, plaintext} -> plaintext
      :error -> value
    end
  end
end
