defmodule ElektrineWeb.NotesLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Notes
  alias Elektrine.Notes.Note

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

      _user ->
        {:ok,
         socket
         |> assign(:page_title, "Notes")
         |> assign(:notes, [])
         |> assign(:search_query, "")
         |> assign(:selected_note, nil)
         |> assign(:selected_note_share, nil)
         |> assign(:selected_note_share_url, nil)
         |> assign(:note_form_mode, :new)
         |> assign_form(Notes.change_note(%Note{}))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    search_query = normalize_query(Map.get(params, "q"))
    notes = Notes.list_notes(user.id, q: search_query)
    selected_note = selected_note(notes, user.id, Map.get(params, "note"))
    selected_note_share = active_share_for(selected_note, user.id)
    new_note? = truthy_param?(Map.get(params, "new"))

    {note_form_mode, note_form} =
      cond do
        new_note? ->
          {:new, Notes.change_note(%Note{})}

        selected_note ->
          {:edit, Notes.change_note(selected_note)}

        true ->
          {:new, Notes.change_note(%Note{})}
      end

    {:noreply,
     socket
     |> assign(:notes, notes)
     |> assign(:search_query, search_query)
     |> assign(:selected_note, selected_note)
     |> assign(:selected_note_share, selected_note_share)
     |> assign(:selected_note_share_url, share_url(selected_note_share))
     |> assign(:note_form_mode, note_form_mode)
     |> assign_form(note_form)}
  end

  @impl true
  def handle_event("filter", %{"filters" => %{"q" => query}}, socket) do
    {:noreply, push_patch(socket, to: notes_path(q: query))}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply, push_patch(socket, to: notes_path(q: socket.assigns.search_query, new: true))}
  end

  def handle_event("validate", %{"note" => params}, socket) do
    note = socket.assigns.selected_note || %Note{}

    changeset =
      note
      |> Notes.change_note(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save_note", %{"note" => params}, socket) do
    case socket.assigns.note_form_mode do
      :edit -> update_note(socket, params)
      :new -> create_note(socket, params)
    end
  end

  def handle_event("delete_note", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, note_id} <- parse_id(id),
         %Note{} = note <- Notes.get_note(user.id, note_id),
         {:ok, _deleted_note} <- Notes.delete_note(note) do
      {:noreply,
       socket
       |> put_flash(:info, "Note deleted")
       |> push_patch(to: notes_path(q: socket.assigns.search_query))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete note")}
    end
  end

  def handle_event("toggle_pin", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, note_id} <- parse_id(id),
         %Note{} = note <- Notes.get_note(user.id, note_id),
         {:ok, toggled_note} <- Notes.toggle_note_pin(note) do
      q = socket.assigns.search_query

      params =
        if socket.assigns.selected_note && socket.assigns.selected_note.id == toggled_note.id,
          do: [q: q, note: toggled_note.id],
          else: [q: q]

      {:noreply, push_patch(socket, to: notes_path(params))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update note")}
    end
  end

  def handle_event("create_share", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, note_id} <- parse_id(id),
         %Note{} = note <- Notes.get_note(user.id, note_id),
         {:ok, _share} <- Notes.create_note_share(user.id, note) do
      {:noreply,
       socket
       |> put_flash(:info, "Share link ready")
       |> push_patch(to: notes_path(q: socket.assigns.search_query, note: note.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not create share link")}
    end
  end

  def handle_event("revoke_share", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, note_id} <- parse_id(id),
         %Note{} = note <- Notes.get_note(user.id, note_id),
         {:ok, _share} <- Notes.revoke_note_share(user.id, note) do
      {:noreply,
       socket
       |> put_flash(:info, "Share link revoked")
       |> push_patch(to: notes_path(q: socket.assigns.search_query, note: note.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not revoke share link")}
    end
  end

  defp create_note(socket, params) do
    user = socket.assigns.current_user

    case Notes.create_note(user.id, params) do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, "Note saved")
         |> push_patch(to: notes_path(q: socket.assigns.search_query, note: note.id))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp update_note(socket, params) do
    case Notes.update_note(socket.assigns.selected_note, params) do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, "Note updated")
         |> push_patch(to: notes_path(q: socket.assigns.search_query, note: note.id))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :update))}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :note))
  end

  defp selected_note(notes, user_id, note_id_param) do
    case parse_id(note_id_param) do
      {:ok, note_id} ->
        Enum.find(notes, &(&1.id == note_id)) || Notes.get_note(user_id, note_id) ||
          List.first(notes)

      :error ->
        List.first(notes)
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error

  defp normalize_query(nil), do: ""
  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(query), do: query |> to_string() |> String.trim()

  defp truthy_param?(value), do: value in [true, "true", "1"]

  defp notes_path(params) do
    params = Enum.reject(params, fn {_key, value} -> value in [nil, "", false] end)
    Elektrine.Paths.notes_path(params)
  end

  def note_title(%Note{title: title, body: body}), do: note_title(title, body)

  def note_preview(%Note{body: body}) do
    body
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "No content yet"
      preview -> String.slice(preview, 0, 120)
    end
  end

  def last_updated_label(%Note{updated_at: nil}), do: nil

  def last_updated_label(%Note{updated_at: updated_at}) do
    Calendar.strftime(updated_at, "%b %-d, %Y %H:%M")
  end

  def selected_note?(%Note{id: id}, %Note{id: selected_id}), do: id == selected_id
  def selected_note?(_note, _selected_note), do: false

  def empty_state_title(%Note{} = note), do: note_title(note)
  def empty_state_title(_note), do: "New note"

  def primary_action_label(:edit), do: "Save changes"
  def primary_action_label(:new), do: "Create note"

  def pin_label(%Note{pinned: true}), do: "Unpin"
  def pin_label(%Note{}), do: "Pin"

  def share_button_label(nil), do: "Create share link"
  def share_button_label(_share), do: "Share link active"

  def active_share_for(%Note{id: id}, user_id), do: Notes.get_active_share_for_note(user_id, id)
  def active_share_for(_note, _user_id), do: nil

  def share_url(nil), do: nil

  def share_url(%{token: token}),
    do: ElektrineWeb.Endpoint.url() <> Elektrine.Paths.note_share_path(token)

  defp note_title(title, body) do
    cond do
      is_binary(title) and title != "" -> title
      is_binary(body) and body != "" -> String.slice(body, 0, 48)
      true -> "Untitled note"
    end
  end
end
