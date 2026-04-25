defmodule Elektrine.Notes do
  @moduledoc """
  Personal note management.
  """
  import Ecto.Query, warn: false

  alias Elektrine.Notes.{Note, NoteShare}
  alias Elektrine.Repo

  @share_expiry_options [
    {"1 hour", "1h"},
    {"1 day", "1d"},
    {"7 days", "7d"},
    {"30 days", "30d"},
    {"Never", "never"}
  ]

  def share_expiry_options, do: @share_expiry_options

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
    |> where([share], is_nil(share.expires_at) or share.expires_at > ^DateTime.utc_now())
    |> where([share], not share.burn_after_read or share.view_count == 0)
    |> preload(note: [:user])
    |> Repo.one()
  end

  def get_public_share(_token), do: nil

  def get_active_share_for_note(user_id, note_id) when is_integer(note_id) do
    NoteShare
    |> where([share], share.user_id == ^user_id and share.note_id == ^note_id)
    |> where([share], is_nil(share.revoked_at))
    |> order_by([share], desc: share.inserted_at, desc: share.id)
    |> limit(1)
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

  def create_encrypted_note_share(user_id, %Note{} = note, payload, opts \\ %{})
      when is_map(payload) do
    with {:ok, expires_at} <- expires_at_from_attrs(opts) do
      attrs = %{
        encrypted_payload: normalize_encrypted_payload(payload),
        expires_at: expires_at,
        burn_after_read:
          truthy?(Map.get(opts, "burn_after_read") || Map.get(opts, :burn_after_read)),
        view_count: 0
      }

      insert_note_share(user_id, note, attrs)
    end
  end

  def revoke_note_share(user_id, %Note{} = note) do
    revoked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _shares} =
      NoteShare
      |> where([share], share.user_id == ^user_id and share.note_id == ^note.id)
      |> where([share], is_nil(share.revoked_at))
      |> Repo.update_all(set: [revoked_at: revoked_at])

    if count > 0 do
      {:ok, %{revoked_count: count}}
    else
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

  defp insert_note_share(user_id, %Note{} = note, attrs \\ %{}) do
    %NoteShare{}
    |> NoteShare.changeset(
      Map.merge(
        %{
          note_id: note.id,
          user_id: user_id,
          token: generate_share_token()
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  defp normalize_encrypted_payload(payload) do
    Map.take(payload, ["version", "algorithm", "iv", "ciphertext"])
  end

  defp expires_at_from_attrs(%{"expires_in" => expires_in}),
    do: expires_at_from_option(expires_in)

  defp expires_at_from_attrs(%{expires_in: expires_in}), do: expires_at_from_option(expires_in)
  defp expires_at_from_attrs(_attrs), do: expires_at_from_option("1d")

  defp expires_at_from_option(nil), do: expires_at_from_option("1d")
  defp expires_at_from_option(""), do: expires_at_from_option("1d")
  defp expires_at_from_option("never"), do: {:ok, nil}

  defp expires_at_from_option("1h"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option("1d"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option("7d"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(604_800, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option("30d"),
    do:
      {:ok, DateTime.utc_now() |> DateTime.add(2_592_000, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option(_), do: {:error, :invalid_share_expiry}

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]

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
