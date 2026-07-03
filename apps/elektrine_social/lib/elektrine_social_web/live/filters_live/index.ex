defmodule ElektrineSocialWeb.FiltersLive.Index do
  use ElektrineSocialWeb, :live_view

  alias Elektrine.Social.Filter
  alias Elektrine.Social.Filters

  import ElektrineSocialWeb.Components.Platform.ENav

  @kind_options [
    {"keyword", "Keyword"},
    {"domain", "Domain"},
    {"actor", "Account"},
    {"community", "Community"},
    {"media", "Media posts"},
    {"sensitive", "Sensitive posts"},
    {"boost", "Boosts"},
    {"reply", "Replies"}
  ]

  @context_options [
    {"home", "Home feed"},
    {"notifications", "Notifications"},
    {"public", "Public timelines"},
    {"thread", "Threads"},
    {"account", "Profiles"}
  ]

  @duration_options [
    {"never", "Never"},
    {"30m", "30 minutes"},
    {"1h", "1 hour"},
    {"1d", "1 day"},
    {"1w", "1 week"}
  ]

  @duration_seconds %{
    "30m" => 30 * 60,
    "1h" => 60 * 60,
    "1d" => 24 * 60 * 60,
    "1w" => 7 * 24 * 60 * 60
  }

  @valueless_kinds ~w(media sensitive boost reply)
  @kinds Filter.kinds()
  @actions Filter.actions()

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user do
      {:ok,
       socket
       |> assign(:page_title, "Filters")
       |> assign(:kind_options, @kind_options)
       |> assign(:context_options, @context_options)
       |> assign(:duration_options, @duration_options)
       |> reset_filter_form()
       |> refresh_filters()}
    else
      {:ok, push_navigate(socket, to: Elektrine.Paths.login_path())}
    end
  end

  @impl true
  def handle_event("update_filter_form", params, socket) do
    {:noreply, assign_form_fields(socket, params)}
  end

  def handle_event("save_filter", params, socket) do
    socket = assign_form_fields(socket, params)
    user_id = socket.assigns.current_user.id
    attrs = filter_attrs(socket.assigns)

    result =
      case socket.assigns.editing_filter_id do
        nil ->
          Filters.create_filter(user_id, attrs)

        filter_id ->
          case get_user_filter(user_id, filter_id) do
            nil -> {:error, :not_found}
            filter -> Filters.update_filter(filter, attrs)
          end
      end

    case result do
      {:ok, _filter} ->
        message =
          if socket.assigns.editing_filter_id, do: "Filter updated", else: "Filter created"

        {:noreply,
         socket
         |> reset_filter_form()
         |> refresh_filters()
         |> put_flash(:info, message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, format_changeset_error(changeset))}

      {:error, :not_found} ->
        {:noreply, socket |> reset_filter_form() |> put_flash(:error, "Filter not found")}
    end
  end

  def handle_event("edit_filter", %{"filter_id" => filter_id}, socket) do
    with {:ok, filter_id} <- parse_positive_int(filter_id),
         %Filter{} = filter <- get_user_filter(socket.assigns.current_user.id, filter_id) do
      {:noreply,
       socket
       |> assign(:editing_filter_id, filter.id)
       |> assign(:filter_kind, filter.kind)
       |> assign(:filter_value, filter.value || "")
       |> assign(:filter_contexts, filter.contexts || [])
       |> assign(:filter_action, filter.action)
       |> assign(:filter_whole_word, filter.whole_word || false)
       |> assign(:filter_expires, "keep")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Filter not found")}
    end
  end

  def handle_event("cancel_edit_filter", _params, socket) do
    {:noreply, reset_filter_form(socket)}
  end

  def handle_event("delete_filter", %{"filter_id" => filter_id}, socket) do
    with {:ok, filter_id} <- parse_positive_int(filter_id),
         {:ok, _filter} <- Filters.delete_filter(filter_id, socket.assigns.current_user.id) do
      socket =
        if socket.assigns.editing_filter_id == filter_id do
          reset_filter_form(socket)
        else
          socket
        end

      {:noreply, socket |> refresh_filters() |> put_flash(:info, "Filter deleted")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Filter not found")}
    end
  end

  defp refresh_filters(socket) do
    assign(socket, :filters, Filters.list_filters(socket.assigns.current_user.id))
  end

  defp get_user_filter(user_id, filter_id) do
    user_id
    |> Filters.list_filters()
    |> Enum.find(&(&1.id == filter_id))
  end

  defp assign_form_fields(socket, params) do
    socket
    |> assign(:filter_kind, normalize_kind(params["kind"], socket.assigns.filter_kind))
    |> assign(:filter_value, to_string(params["value"] || socket.assigns.filter_value))
    |> assign(:filter_contexts, normalize_contexts(params))
    |> assign(:filter_action, normalize_action(params["action"], socket.assigns.filter_action))
    |> assign(:filter_whole_word, truthy?(params["whole_word"]))
    |> assign(
      :filter_expires,
      normalize_duration(params["expires"], socket.assigns.filter_expires)
    )
  end

  defp filter_attrs(assigns) do
    attrs = %{
      kind: assigns.filter_kind,
      value: if(value_required?(assigns.filter_kind), do: assigns.filter_value),
      contexts: assigns.filter_contexts,
      action: assigns.filter_action,
      whole_word: assigns.filter_whole_word
    }

    case assigns.filter_expires do
      "keep" ->
        attrs

      "never" ->
        Map.put(attrs, :expires_at, nil)

      duration ->
        seconds = Map.fetch!(@duration_seconds, duration)

        Map.put(
          attrs,
          :expires_at,
          DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
        )
    end
  end

  defp reset_filter_form(socket) do
    socket
    |> assign(:editing_filter_id, nil)
    |> assign(:filter_kind, "keyword")
    |> assign(:filter_value, "")
    |> assign(:filter_contexts, [])
    |> assign(:filter_action, "hide")
    |> assign(:filter_whole_word, false)
    |> assign(:filter_expires, "never")
  end

  defp normalize_kind(kind, _fallback) when kind in @kinds, do: kind
  defp normalize_kind(_kind, fallback), do: fallback

  defp normalize_action(action, _fallback) when action in @actions, do: action
  defp normalize_action(_action, fallback), do: fallback

  defp normalize_contexts(params) do
    params
    |> Map.get("contexts", [])
    |> List.wrap()
    |> Enum.filter(&(&1 in Filter.contexts()))
    |> Enum.uniq()
  end

  defp normalize_duration("keep", _fallback), do: "keep"

  defp normalize_duration(duration, _fallback)
       when duration == "never" or is_map_key(@duration_seconds, duration),
       do: duration

  defp normalize_duration(_duration, fallback), do: fallback

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  def value_required?(kind), do: kind not in @valueless_kinds

  def kind_label(kind) do
    Enum.find_value(@kind_options, kind, fn {value, label} ->
      if value == kind, do: label
    end)
  end

  def context_label(context) do
    Enum.find_value(@context_options, context, fn {value, label} ->
      if value == context, do: label
    end)
  end

  def value_placeholder("keyword"), do: "Word or phrase to filter"
  def value_placeholder("domain"), do: "example.social"
  def value_placeholder("actor"), do: "user@example.social or actor URL"
  def value_placeholder("community"), do: "https://example.social/c/community"
  def value_placeholder(_kind), do: ""

  def expires_label(nil), do: "Never expires"

  def expires_label(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      "Expired"
    else
      "Expires " <> Calendar.strftime(expires_at, "%b %-d, %Y %H:%M UTC")
    end
  end

  defp format_changeset_error(%Ecto.Changeset{errors: [{field, error} | _]}) do
    "#{field} #{translate_error(error)}"
  end

  defp format_changeset_error(_changeset), do: "Failed to save filter"
end
