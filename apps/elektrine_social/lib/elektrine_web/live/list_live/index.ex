defmodule ElektrineWeb.ListLive.Index do
  use ElektrineSocialWeb, :live_view

  alias Elektrine.Social

  import ElektrineWeb.Components.Platform.ZNav

  @discover_fetch_limit 50
  @discover_display_limit 20
  @list_views ~w(my_lists discover)
  @list_visibility_filters ~w(all public private)
  @list_visibility_options ~w(public private)
  @list_sort_options ~w(name fresh members)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user do
      {:ok,
       socket
       |> assign(:page_title, "Lists")
       |> assign(:view_mode, "my_lists")
       |> assign(:my_lists_query, "")
       |> assign(:my_lists_visibility, "all")
       |> assign(:my_lists_sort, "name")
       |> assign(:discover_query, "")
       |> assign(:discover_sort, "fresh")
       |> assign(:new_list_name, "")
       |> assign(:new_list_description, "")
       |> assign(:new_list_visibility, "private")
       |> refresh_list_data()}
    else
      {:ok, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, normalize_view_mode(mode, socket.assigns.view_mode))}
  end

  def handle_event("search_my_lists", params, socket) do
    {:noreply, socket |> assign(:my_lists_query, extract_query(params)) |> apply_filters()}
  end

  def handle_event("clear_my_lists_search", _params, socket) do
    {:noreply, socket |> assign(:my_lists_query, "") |> apply_filters()}
  end

  def handle_event("set_my_lists_visibility", %{"visibility" => visibility}, socket) do
    {:noreply,
     socket
     |> assign(:my_lists_visibility, normalize_visibility_filter(visibility))
     |> apply_filters()}
  end

  def handle_event("set_my_lists_sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(:my_lists_sort, normalize_sort(sort, "name")) |> apply_filters()}
  end

  def handle_event("search_lists", params, socket) do
    query = extract_query(params)

    {:noreply,
     socket
     |> assign(:discover_query, query)
     |> assign(:public_lists, load_public_lists(socket.assigns.current_user.id, query))
     |> apply_filters()}
  end

  def handle_event("clear_discover_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:discover_query, "")
     |> assign(:public_lists, load_public_lists(socket.assigns.current_user.id, ""))
     |> apply_filters()}
  end

  def handle_event("set_public_lists_sort", %{"sort" => sort}, socket) do
    {:noreply,
     socket
     |> assign(:discover_sort, normalize_sort(sort, "fresh"))
     |> apply_filters()}
  end

  def handle_event("update_new_list_form", params, socket) do
    {:noreply,
     socket
     |> assign(:new_list_name, Map.get(params, "name", socket.assigns.new_list_name))
     |> assign(
       :new_list_description,
       Map.get(params, "description", socket.assigns.new_list_description)
     )
     |> assign(
       :new_list_visibility,
       normalize_list_visibility(
         Map.get(params, "visibility", socket.assigns.new_list_visibility),
         socket.assigns.new_list_visibility
       )
     )}
  end

  def handle_event("reset_new_list_form", _params, socket) do
    {:noreply, reset_new_list_form(socket)}
  end

  def handle_event("create_list", params, socket) do
    name = Map.get(params, "name", socket.assigns.new_list_name)
    description = Map.get(params, "description", socket.assigns.new_list_description)

    visibility =
      normalize_list_visibility(
        Map.get(params, "visibility", socket.assigns.new_list_visibility),
        socket.assigns.new_list_visibility
      )

    attrs = %{
      user_id: socket.assigns.current_user.id,
      name: String.trim(name),
      description: String.trim(description),
      visibility: visibility
    }

    case Social.create_list(attrs) do
      {:ok, _list} ->
        {:noreply,
         socket
         |> reset_new_list_form()
         |> assign(:view_mode, "my_lists")
         |> refresh_list_data()
         |> put_flash(:info, "List created successfully")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:new_list_name, name)
         |> assign(:new_list_description, description)
         |> assign(:new_list_visibility, visibility)
         |> assign(:view_mode, "my_lists")
         |> put_flash(:error, format_changeset_error(changeset))}
    end
  end

  def handle_event("delete_list", %{"list_id" => list_id}, socket) do
    list_id = String.to_integer(list_id)

    case Social.get_user_list(socket.assigns.current_user.id, list_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "List not found")}

      list ->
        case Social.delete_list(list) do
          {:ok, _} ->
            {:noreply, socket |> refresh_list_data() |> put_flash(:info, "List deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete list")}
        end
    end
  end

  defp refresh_list_data(socket) do
    user_id = socket.assigns.current_user.id
    lists = Social.list_user_lists(user_id)
    public_lists = load_public_lists(user_id, socket.assigns.discover_query)

    socket
    |> assign(:lists, lists)
    |> assign(:public_lists, public_lists)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    filtered_lists =
      socket.assigns.lists
      |> filter_user_lists(socket.assigns.my_lists_query, socket.assigns.my_lists_visibility)
      |> sort_lists(socket.assigns.my_lists_sort)

    filtered_public_lists =
      socket.assigns.public_lists
      |> sort_lists(socket.assigns.discover_sort)
      |> Enum.take(@discover_display_limit)

    list_stats = %{
      my_lists: length(socket.assigns.lists),
      public_lists: Enum.count(socket.assigns.lists, &(&1.visibility == "public")),
      total_members: Enum.reduce(socket.assigns.lists, 0, &(member_count(&1) + &2)),
      discover_results: length(filtered_public_lists)
    }

    socket
    |> assign(:filtered_lists, filtered_lists)
    |> assign(:filtered_public_lists, filtered_public_lists)
    |> assign(:list_stats, list_stats)
  end

  defp load_public_lists(user_id, query) do
    query = String.trim(query || "")

    public_lists =
      if String.length(query) >= 2 do
        Social.search_public_lists(query, limit: @discover_fetch_limit)
      else
        Social.list_public_lists(limit: @discover_fetch_limit)
      end

    public_lists
    |> Enum.reject(&(&1.user_id == user_id))
  end

  defp filter_user_lists(lists, query, visibility) do
    normalized_query = String.downcase(String.trim(query || ""))

    lists
    |> Enum.filter(&(visibility_matches?(&1, visibility) and query_matches?(&1, normalized_query)))
  end

  defp visibility_matches?(_list, "all"), do: true
  defp visibility_matches?(list, visibility), do: list.visibility == visibility

  defp query_matches?(_list, ""), do: true

  defp query_matches?(list, query) do
    list
    |> list_search_text()
    |> String.contains?(query)
  end

  defp list_search_text(list) do
    ([list.name, list.description] ++ Enum.map(list.list_members || [], &member_search_text/1))
    |> Enum.reject(&blank_text?/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp member_search_text(%{user: %{username: username} = user}) do
    [username, Map.get(user, :display_name)]
    |> Enum.reject(&blank_text?/1)
    |> Enum.join(" ")
  end

  defp member_search_text(%{remote_actor: %{username: username} = actor}) do
    [username, Map.get(actor, :display_name), Map.get(actor, :domain)]
    |> Enum.reject(&blank_text?/1)
    |> Enum.join(" ")
  end

  defp member_search_text(_member), do: ""

  defp blank_text?(value), do: value in [nil, ""]

  defp sort_lists(lists, "fresh") do
    lists
    |> Enum.sort_by(&String.downcase(&1.name || ""))
    |> Enum.sort_by(&sort_timestamp(&1.updated_at || &1.inserted_at), :desc)
  end

  defp sort_lists(lists, "members") do
    lists
    |> Enum.sort_by(&String.downcase(&1.name || ""))
    |> Enum.sort_by(&member_count/1, :desc)
  end

  defp sort_lists(lists, _sort) do
    Enum.sort_by(lists, &String.downcase(&1.name || ""))
  end

  defp member_count(list), do: length(list.list_members || [])

  defp sort_timestamp(%NaiveDateTime{} = datetime),
    do: :calendar.datetime_to_gregorian_seconds(NaiveDateTime.to_erl(datetime))

  defp sort_timestamp(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp sort_timestamp(_datetime), do: 0

  defp extract_query(params) do
    params
    |> Map.get("query", Map.get(params, "value", ""))
    |> to_string()
    |> String.trim()
  end

  defp normalize_view_mode(mode, _fallback) when mode in @list_views, do: mode
  defp normalize_view_mode(_mode, fallback), do: fallback

  defp normalize_visibility_filter(visibility) when visibility in @list_visibility_filters,
    do: visibility

  defp normalize_visibility_filter(_visibility), do: "all"

  defp normalize_list_visibility(visibility, _fallback)
       when visibility in @list_visibility_options,
       do: visibility

  defp normalize_list_visibility(_visibility, fallback), do: fallback

  defp normalize_sort(sort, _fallback) when sort in @list_sort_options, do: sort
  defp normalize_sort(_sort, fallback), do: fallback

  defp reset_new_list_form(socket) do
    socket
    |> assign(:new_list_name, "")
    |> assign(:new_list_description, "")
    |> assign(:new_list_visibility, "private")
  end

  defp format_changeset_error(%Ecto.Changeset{errors: [{_field, error} | _]}) do
    translate_error(error)
  end

  defp format_changeset_error(_changeset), do: "Failed to create list"
end
