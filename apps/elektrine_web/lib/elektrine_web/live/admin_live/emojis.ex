defmodule ElektrineWeb.AdminLive.Emojis do
  use ElektrineWeb, :live_view
  alias Elektrine.Emojis

  @impl true
  def mount(_params, _session, socket) do
    emojis = Emojis.list_all_emojis(limit: 50)
    categories = Emojis.list_categories()
    total = Emojis.count_emojis()

    {:ok,
     socket
     |> assign(:page_title, "Custom Emoji Management")
     |> assign(:emojis, emojis)
     |> assign(:categories, categories)
     |> assign(:total_count, total)
     |> assign(:search_query, "")
     |> assign(:filter, "all")
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:show_form, false)
     |> assign(:editing_emoji, nil)
     |> assign(:form, to_form(%{}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply, assign(socket, show_form: false, editing_emoji: nil)}

      :new ->
        {:noreply,
         socket
         |> assign(:show_form, true)
         |> assign(:editing_emoji, nil)
         |> assign(
           :form,
           to_form(%{
             "shortcode" => "",
             "image_url" => "",
             "category" => "",
             "visible_in_picker" => true
           })
         )}

      :edit ->
        emoji_id = params["id"]
        emoji = Emojis.get_emoji(emoji_id)

        if emoji do
          {:noreply,
           socket
           |> assign(:show_form, true)
           |> assign(:editing_emoji, emoji)
           |> assign(
             :form,
             to_form(%{
               "shortcode" => emoji.shortcode,
               "image_url" => emoji.image_url,
               "category" => emoji.category || "",
               "visible_in_picker" => emoji.visible_in_picker
             })
           )}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Emoji not found")
           |> push_patch(to: ~p"/pripyat/emojis")}
        end
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    emojis =
      Emojis.list_all_emojis(
        limit: socket.assigns.per_page,
        search: query,
        filter: socket.assigns.filter
      )

    total = Emojis.count_emojis(search: query, filter: socket.assigns.filter)

    {:noreply,
     socket
     |> assign(:emojis, emojis)
     |> assign(:total_count, total)
     |> assign(:search_query, query)
     |> assign(:page, 1)}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    emojis =
      Emojis.list_all_emojis(
        limit: socket.assigns.per_page,
        search: socket.assigns.search_query,
        filter: filter
      )

    total = Emojis.count_emojis(search: socket.assigns.search_query, filter: filter)

    {:noreply,
     socket
     |> assign(:emojis, emojis)
     |> assign(:total_count, total)
     |> assign(:filter, filter)
     |> assign(:page, 1)}
  end

  def handle_event("load_more", _params, socket) do
    page = socket.assigns.page + 1
    offset = (page - 1) * socket.assigns.per_page

    more_emojis =
      Emojis.list_all_emojis(
        limit: socket.assigns.per_page,
        offset: offset,
        search: socket.assigns.search_query,
        filter: socket.assigns.filter
      )

    if Enum.empty?(more_emojis) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> update(:emojis, fn existing -> existing ++ more_emojis end)
       |> assign(:page, page)}
    end
  end

  def handle_event("toggle_disabled", %{"id" => id}, socket) do
    emoji = Emojis.get_emoji(id)

    case Emojis.toggle_emoji_disabled(emoji) do
      {:ok, updated_emoji} ->
        {:noreply,
         socket
         |> update(:emojis, fn emojis ->
           Enum.map(emojis, fn e -> if e.id == updated_emoji.id, do: updated_emoji, else: e end)
         end)
         |> put_flash(
           :info,
           if(updated_emoji.disabled, do: "Emoji disabled", else: "Emoji enabled")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update emoji")}
    end
  end

  def handle_event("toggle_visibility", %{"id" => id}, socket) do
    emoji = Emojis.get_emoji(id)

    case Emojis.toggle_emoji_visibility(emoji) do
      {:ok, updated_emoji} ->
        {:noreply,
         socket
         |> update(:emojis, fn emojis ->
           Enum.map(emojis, fn e -> if e.id == updated_emoji.id, do: updated_emoji, else: e end)
         end)
         |> put_flash(
           :info,
           if(updated_emoji.visible_in_picker,
             do: "Now visible in picker",
             else: "Hidden from picker"
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update emoji")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    emoji = Emojis.get_emoji(id)

    case Emojis.delete_emoji(emoji) do
      {:ok, _} ->
        {:noreply,
         socket
         |> update(:emojis, fn emojis -> Enum.reject(emojis, &(&1.id == emoji.id)) end)
         |> update(:total_count, fn count -> count - 1 end)
         |> put_flash(:info, "Emoji deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete emoji")}
    end
  end

  def handle_event("save", params, socket) do
    attrs = %{
      shortcode: params["shortcode"],
      image_url: params["image_url"],
      category: if(params["category"] == "", do: nil, else: params["category"]),
      visible_in_picker: params["visible_in_picker"] == "true"
    }

    result =
      if socket.assigns.editing_emoji do
        Emojis.update_emoji(socket.assigns.editing_emoji, attrs)
      else
        Emojis.create_emoji(attrs)
      end

    case result do
      {:ok, emoji} ->
        # Refresh the list
        emojis =
          Emojis.list_all_emojis(
            limit: socket.assigns.per_page,
            search: socket.assigns.search_query,
            filter: socket.assigns.filter
          )

        categories = Emojis.list_categories()

        action = if socket.assigns.editing_emoji, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(:emojis, emojis)
         |> assign(:categories, categories)
         |> assign(:show_form, false)
         |> assign(:editing_emoji, nil)
         |> put_flash(:info, "Emoji :#{emoji.shortcode}: #{action} successfully!")
         |> push_patch(to: ~p"/pripyat/emojis")}

      {:error, changeset} ->
        errors = format_errors(changeset)
        {:noreply, put_flash(socket, :error, "Failed to save: #{errors}")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/pripyat/emojis")}
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end
end
