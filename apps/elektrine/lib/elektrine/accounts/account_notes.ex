defmodule Elektrine.Accounts.AccountNotes do
  @moduledoc """
  Private account notes, compatible with Mastodon/Pleroma account notes.
  """

  import Ecto.Query

  alias Elektrine.Accounts.AccountNote
  alias Elektrine.Repo

  def get_note(source_user_id, {:user, target_user_id}) do
    Repo.get_by(AccountNote, source_user_id: source_user_id, target_user_id: target_user_id)
  end

  def get_note(source_user_id, {:remote_actor, target_remote_actor_id}) do
    Repo.get_by(AccountNote,
      source_user_id: source_user_id,
      target_remote_actor_id: target_remote_actor_id
    )
  end

  def note_comment(source_user_id, target) do
    case get_note(source_user_id, target) do
      %AccountNote{comment: comment} when is_binary(comment) -> comment
      _ -> ""
    end
  end

  def put_note(source_user_id, {:user, target_user_id}, comment) do
    upsert_note(%{
      source_user_id: source_user_id,
      target_user_id: target_user_id,
      comment: comment
    })
  end

  def put_note(source_user_id, {:remote_actor, target_remote_actor_id}, comment) do
    upsert_note(%{
      source_user_id: source_user_id,
      target_remote_actor_id: target_remote_actor_id,
      comment: comment
    })
  end

  def delete_blank_notes do
    from(note in AccountNote,
      where: is_nil(note.comment) or note.comment == ""
    )
    |> Repo.delete_all()
  end

  defp upsert_note(attrs) do
    lookup =
      cond do
        attrs[:target_user_id] ->
          [source_user_id: attrs.source_user_id, target_user_id: attrs.target_user_id]

        attrs[:target_remote_actor_id] ->
          [
            source_user_id: attrs.source_user_id,
            target_remote_actor_id: attrs.target_remote_actor_id
          ]
      end

    case Repo.get_by(AccountNote, lookup) do
      nil ->
        %AccountNote{}
        |> AccountNote.changeset(attrs)
        |> Repo.insert()

      note ->
        note
        |> AccountNote.changeset(attrs)
        |> Repo.update()
    end
  end
end
