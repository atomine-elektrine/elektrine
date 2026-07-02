defmodule ElektrineSocialWeb.RemoteUserLive.MediaModal do
  @moduledoc """
  Prev/next navigation across a remote user's media posts inside the image modal.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Elektrine.Social.Message

  def navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    media_posts = media_posts_for_modal(socket.assigns[:local_posts] || [])

    with current_ref when not is_nil(current_ref) <- modal_post_ref(modal_post),
         current_index when is_integer(current_index) <-
           Enum.find_index(media_posts, &(post_ref(&1) == current_ref)),
         total when total > 0 <- length(media_posts),
         new_post <- Enum.at(media_posts, next_media_index(current_index, total, direction)),
         images when images != [] <- List.wrap(new_post.media_urls) do
      modal_post = attach_modal_remote_actor(new_post, socket.assigns[:remote_actor])

      {:noreply,
       socket
       |> assign(:modal_post, modal_post)
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, 0)
       |> assign(:modal_image_url, List.first(images))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp media_posts_for_modal(posts) do
    Enum.filter(posts, fn post ->
      post
      |> Map.get(:media_urls, [])
      |> List.wrap()
      |> Enum.any?(&is_binary/1)
    end)
  end

  defp next_media_index(current_index, total, :next), do: rem(current_index + 1, total)
  defp next_media_index(current_index, total, :prev), do: rem(current_index - 1 + total, total)

  defp modal_post_ref(nil), do: nil
  defp modal_post_ref(post), do: post_ref(post)

  defp post_ref(post), do: Map.get(post, :activitypub_id) || Map.get(post, :id)

  defp attach_modal_remote_actor(post, nil), do: post

  defp attach_modal_remote_actor(%Message{} = post, remote_actor) do
    %{post | remote_actor: remote_actor}
  end

  defp attach_modal_remote_actor(post, remote_actor) when is_map(post) do
    Map.put(post, :remote_actor, remote_actor)
  end
end
