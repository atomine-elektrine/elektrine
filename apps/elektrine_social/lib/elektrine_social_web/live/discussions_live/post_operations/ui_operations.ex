defmodule ElektrineSocialWeb.DiscussionsLive.PostOperations.UIOperations do
  @moduledoc """
  Handles UI operations for discussion post detail view.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("copy_discussion_link", %{"message_id" => message_id}, socket) do
    title =
      case socket.assigns[:post] do
        %{id: id, title: title} ->
          if to_string(id) == to_string(message_id), do: title

        _ ->
          nil
      end

    post_url =
      ElektrineWeb.Endpoint.url() <>
        Elektrine.Paths.discussion_post_path(socket.assigns.community.name, message_id, title)

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: post_url})
     |> notify_info("Link copied to clipboard")}
  end

  def handle_event("copy_link", %{"message_id" => _message_id}, socket) do
    post = socket.assigns.post

    path =
      Elektrine.Paths.discussion_post_path(socket.assigns.community.name, post.id, post.title)

    url = ElektrineWeb.Endpoint.url() <> path

    {:noreply, push_event(socket, "copy_to_clipboard", %{text: url})}
  end

  def handle_event("mute_thread", _params, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, notify_error(socket, "You must be signed in to mute conversations")}

      user ->
        case Elektrine.Social.ThreadMutes.mute_thread(user.id, socket.assigns.post) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:thread_muted, true)
             |> notify_info("Conversation muted")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to mute conversation")}
        end
    end
  end

  def handle_event("unmute_thread", _params, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, socket}

      user ->
        _ = Elektrine.Social.ThreadMutes.unmute_thread(user.id, socket.assigns.post)

        {:noreply,
         socket
         |> assign(:thread_muted, false)
         |> notify_info("Conversation unmuted")}
    end
  end

  def handle_event("mute_user", %{"user_id" => user_id} = params, socket) do
    handle_user_mute(socket, user_id, :mute, params["duration"])
  end

  def handle_event("unmute_user", %{"user_id" => user_id}, socket) do
    handle_user_mute(socket, user_id, :unmute, nil)
  end

  def handle_event("mute_remote_actor", %{"actor_id" => actor_id}, socket) do
    handle_remote_actor_mute(socket, actor_id, :mute)
  end

  def handle_event("unmute_remote_actor", %{"actor_id" => actor_id}, socket) do
    handle_remote_actor_mute(socket, actor_id, :unmute)
  end

  def handle_event("report_discussion", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        {:noreply, open_report_modal(socket, message_id)}

      :error ->
        {:noreply, notify_error(socket, "Post not found")}
    end
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})}
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    with {:ok, images} when is_list(images) <- Jason.decode(images_json),
         {:ok, index_int} <- parse_non_negative_int(index) do
      url = params["url"] || Enum.at(images, index_int, List.first(images))

      {:noreply,
       socket
       |> assign(:show_image_modal, true)
       |> assign(:modal_image_url, url)
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, index_int)
       |> assign(:modal_post, modal_post(params["post_id"], socket))}
    else
      _ -> {:noreply, notify_error(socket, "Unable to open image")}
    end
  end

  # close_image_modal / next_image / prev_image are delegated to the shared
  # ElektrineSocialWeb.TimelineLive.Operations.ImageOperations via the post router,
  # since they only operate on the canonical modal-state assigns.

  defp handle_user_mute(socket, user_id, action, duration) do
    user = socket.assigns[:current_user]

    with %{id: muter_id} <- user,
         {:ok, target_id} when target_id != muter_id <- parse_positive_int(user_id) do
      case action do
        :mute ->
          expires_in =
            case Integer.parse(to_string(duration)) do
              {seconds, ""} when seconds > 0 -> seconds
              _ -> nil
            end

          case Elektrine.Accounts.mute_user(muter_id, target_id, false, expires_in) do
            {:ok, _} -> {:noreply, notify_info(socket, "User muted")}
            {:error, _} -> {:noreply, notify_error(socket, "Failed to mute user")}
          end

        :unmute ->
          _ = Elektrine.Accounts.unmute_user(muter_id, target_id)
          {:noreply, notify_info(socket, "User unmuted")}
      end
    else
      nil -> {:noreply, notify_error(socket, "You must be signed in to mute users")}
      _ -> {:noreply, socket}
    end
  end

  defp handle_remote_actor_mute(socket, actor_id, action) do
    user = socket.assigns[:current_user]

    with %{id: muter_id} <- user,
         {:ok, actor_id} <- parse_positive_int(actor_id) do
      case action do
        :mute ->
          case Elektrine.Accounts.mute_remote_actor(muter_id, actor_id) do
            {:ok, _} -> {:noreply, notify_info(socket, "User muted")}
            {:error, _} -> {:noreply, notify_error(socket, "Failed to mute user")}
          end

        :unmute ->
          _ = Elektrine.Accounts.unmute_remote_actor(muter_id, actor_id)
          {:noreply, notify_info(socket, "User unmuted")}
      end
    else
      nil -> {:noreply, notify_error(socket, "You must be signed in to mute users")}
      _ -> {:noreply, socket}
    end
  end

  defp open_report_modal(socket, message_id) do
    post = socket.assigns.post

    report_metadata = %{
      "sender_id" => post.sender_id,
      "community_id" => socket.assigns.community.id,
      "community_name" => socket.assigns.community.name,
      "content_preview" => ElektrineWeb.HtmlHelpers.plain_text_preview(post.content, 100),
      "title" => ElektrineWeb.HtmlHelpers.plain_text_content(post.title),
      "source" => "discussion_detail"
    }

    socket
    |> assign(:show_report_modal, true)
    |> assign(:report_type, "message")
    |> assign(:report_id, message_id)
    |> assign(:report_metadata, report_metadata)
  end

  defp modal_post(nil, socket), do: socket.assigns.post

  defp modal_post(post_id, socket) do
    case parse_positive_int(post_id) do
      {:ok, post_id} ->
        if socket.assigns.post.id == post_id, do: socket.assigns.post

      :error ->
        nil
    end
  end

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_non_negative_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end
end
