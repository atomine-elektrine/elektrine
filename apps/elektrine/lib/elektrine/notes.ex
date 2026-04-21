defmodule Elektrine.Notes do
  @moduledoc """
  Personal note management.
  """
  import Ecto.Query, warn: false

  alias Elektrine.Notes.{Note, NoteShare}
  alias Elektrine.Repo

  def list_notes(user_id, opts \\ []) do
    query = normalize_query(Keyword.get(opts, :q) || Map.get(Map.new(opts), "q"))

    Note
    |> where([note], note.user_id == ^user_id)
    |> maybe_filter_query(query)
    |> order_by([note], desc: note.pinned, desc: note.updated_at, desc: note.id)
    |> Repo.all()
  end

  def get_note(user_id, id) when is_integer(id) do
    Repo.get_by(Note, id: id, user_id: user_id)
  end

  def get_note(_user_id, _id), do: nil

  def get_public_share(token) when is_binary(token) do
    NoteShare
    |> where([share], share.token == ^String.trim(token))
    |> where([share], is_nil(share.revoked_at))
    |> preload(note: [:user])
    |> Repo.one()
  end

  def get_public_share(_token), do: nil

  def get_active_share_for_note(user_id, note_id) when is_integer(note_id) do
    NoteShare
    |> where([share], share.user_id == ^user_id and share.note_id == ^note_id)
    |> where([share], is_nil(share.revoked_at))
    |> order_by([share], desc: share.inserted_at, desc: share.id)
    |> Repo.one()
  end

  def get_active_share_for_note(_user_id, _note_id), do: nil

  def create_note(user_id, attrs \\ %{}) do
    attrs = attrs |> Map.new() |> stringify_keys() |> Map.put("user_id", user_id)

    %Note{}
    |> Note.changeset(attrs)
    |> Repo.insert()
  end

  def update_note(%Note{} = note, attrs) do
    note
    |> Note.changeset(attrs)
    |> Repo.update()
  end

  def delete_note(%Note{} = note) do
    Repo.delete(note)
  end

  def create_note_share(user_id, %Note{} = note) do
    case get_active_share_for_note(user_id, note.id) do
      %NoteShare{} = share -> {:ok, share}
      nil -> insert_note_share(user_id, note)
    end
  end

  def revoke_note_share(user_id, %Note{} = note) do
    case get_active_share_for_note(user_id, note.id) do
      %NoteShare{} = share ->
        share
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  def increment_share_view_count(%NoteShare{} = share) do
    share
    |> Ecto.Changeset.change(view_count: (share.view_count || 0) + 1)
    |> Repo.update()
  end

  def toggle_note_pin(%Note{} = note) do
    update_note(note, %{pinned: !note.pinned})
  end

  def change_note(%Note{} = note, attrs \\ %{}) do
    Note.changeset(note, attrs)
  end

  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, search_query) do
    pattern = "%#{search_query}%"

    where(
      query,
      [note],
      ilike(fragment("coalesce(?, '')", note.title), ^pattern) or
        ilike(fragment("coalesce(?, '')", note.body), ^pattern)
    )
  end

  defp normalize_query(nil), do: ""
  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(query), do: query |> to_string() |> String.trim()

  defp insert_note_share(user_id, %Note{} = note) do
    %NoteShare{}
    |> NoteShare.changeset(%{
      note_id: note.id,
      user_id: user_id,
      token: generate_share_token()
    })
    |> Repo.insert()
  end

  defp generate_share_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
