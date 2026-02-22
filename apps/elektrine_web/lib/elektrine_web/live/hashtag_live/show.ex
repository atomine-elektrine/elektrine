defmodule ElektrineWeb.HashtagLive.Show do
  use ElektrineWeb, :live_view
  alias Elektrine.Social
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost
  import ElektrineWeb.Live.Helpers.PostStateHelpers
  @impl true
  def mount(%{"hashtag" => hashtag_name}, _session, socket) do
    posts = Social.get_posts_for_hashtag(hashtag_name, limit: 20)
    hashtag_info = get_hashtag_info(hashtag_name)
    trending_hashtags = Social.get_trending_hashtags(limit: 10)

    {user_likes, user_boosts} =
      case socket.assigns[:current_user] do
        %{id: user_id} -> {get_user_likes(user_id, posts), get_user_boosts(user_id, posts)}
        _ -> {%{}, %{}}
      end

    {:ok,
     socket
     |> assign(:page_title, "##{hashtag_name}")
     |> assign(:hashtag_name, hashtag_name)
     |> assign(:hashtag_info, hashtag_info)
     |> assign(:posts, posts)
     |> assign(:trending_hashtags, trending_hashtags)
     |> assign(:loading_more, false)
     |> assign(:user_likes, user_likes)
     |> assign(:user_boosts, user_boosts)
     |> assign(:show_post_composer, false)
     |> assign(:post_content, "")
     |> assign(:post_visibility, "public")
     |> assign(:end_of_feed, length(posts) < 20)
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    handle_event("load_more_posts", %{}, socket)
  end

  def handle_event("load_more_posts", _params, socket) do
    if socket.assigns.loading_more || socket.assigns.end_of_feed do
      {:noreply, socket}
    else
      current_posts = socket.assigns.posts

      before_id =
        if Enum.empty?(current_posts) do
          nil
        else
          List.last(current_posts).id
        end

      more_posts =
        Social.get_posts_for_hashtag(socket.assigns.hashtag_name, limit: 20, before_id: before_id)

      {:noreply,
       socket
       |> assign(:loading_more, false)
       |> assign(:end_of_feed, length(more_posts) < 20)
       |> update(:posts, fn posts -> posts ++ more_posts end)}
    end
  end

  def handle_event("unlike_post", params, socket) do
    handle_event("like_post", params, socket)
  end

  def handle_event("unboost_post", params, socket) do
    handle_event("boost_post", params, socket)
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, socket |> put_flash(:error, "You must be logged in to like posts")}

      %{id: user_id} ->
        message_id = SafeConvert.to_integer!(message_id, message_id)

        case Map.get(socket.assigns.user_likes, message_id, false) do
          true ->
            updated_socket =
              socket
              |> update_post_in_hashtag_feed(message_id, :decrement_likes)
              |> update_user_like_status(message_id, false)

            case Social.unlike_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply, updated_socket}

              {:error, _} ->
                {:noreply,
                 updated_socket
                 |> update_post_in_hashtag_feed(message_id, :increment_likes)
                 |> update_user_like_status(message_id, true)
                 |> put_flash(:error, "Failed to unlike post")}
            end

          false ->
            updated_socket =
              socket
              |> update_post_in_hashtag_feed(message_id, :increment_likes)
              |> update_user_like_status(message_id, true)

            case Social.like_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply, updated_socket}

              {:error, _} ->
                {:noreply,
                 updated_socket
                 |> update_post_in_hashtag_feed(message_id, :decrement_likes)
                 |> update_user_like_status(message_id, false)
                 |> put_flash(:error, "Failed to like post")}
            end
        end
    end
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("open_external_link", %{"url" => url}, socket) do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event(
        "open_image_modal",
        %{"url" => url, "images" => images_json, "index" => index, "post_id" => post_id},
        socket
      ) do
    images = Jason.decode!(images_json)
    post_id_int = String.to_integer(post_id)
    modal_post = Enum.find(socket.assigns.posts, fn post -> post.id == post_id_int end)

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, String.to_integer(index))
     |> assign(:modal_post, modal_post)}
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("next_image", _params, socket) do
    new_index = rem(socket.assigns.modal_image_index + 1, length(socket.assigns.modal_images))
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
  end

  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)
    new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
  end

  def handle_event("navigate_to_post", %{"id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/remote/post/#{post_id}")}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("toggle_post_composer", _params, socket) do
    {:noreply, assign(socket, :show_post_composer, !socket.assigns.show_post_composer)}
  end

  def handle_event("update_post_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :post_content, content)}
  end

  def handle_event("update_post_visibility", %{"visibility" => visibility}, socket) do
    {:noreply, assign(socket, :post_visibility, visibility)}
  end

  def handle_event(
        "create_hashtag_post",
        %{"content" => content, "visibility" => visibility},
        socket
      ) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      hashtag = "##{socket.assigns.hashtag_name}"

      content_with_hashtag =
        if String.contains?(content, hashtag) do
          content
        else
          "#{content} #{hashtag}"
        end

      case Social.create_timeline_post(user_id, content_with_hashtag, visibility: visibility) do
        {:ok, new_post} ->
          new_post = Elektrine.Repo.preload(new_post, sender: [:profile], hashtags: [])

          updated_info = %{
            socket.assigns.hashtag_info
            | use_count: socket.assigns.hashtag_info.use_count + 1,
              last_used_at: DateTime.utc_now()
          }

          {:noreply,
           socket
           |> assign(:show_post_composer, false)
           |> assign(:post_content, "")
           |> assign(:hashtag_info, updated_info)
           |> update(:posts, fn posts -> [new_post | posts] end)
           |> update(:user_likes, fn likes -> Map.put(likes, new_post.id, false) end)
           |> update(:user_boosts, fn boosts -> Map.put(boosts, new_post.id, false) end)
           |> put_flash(:info, "Post created!")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create post")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to post")}
    end
  end

  def handle_event("", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      message_id = String.to_integer(message_id)

      case Map.get(socket.assigns.user_boosts, message_id, false) do
        true ->
          case Social.unboost_post(user_id, message_id) do
            {:ok, _} ->
              updated_posts =
                Enum.map(socket.assigns.posts, fn post ->
                  if post.id == message_id do
                    %{post | share_count: max(0, (post.share_count || 0) - 1)}
                  else
                    post
                  end
                end)

              {:noreply,
               socket
               |> assign(:posts, updated_posts)
               |> assign(:user_boosts, Map.put(socket.assigns.user_boosts, message_id, false))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unboost")}
          end

        false ->
          case Social.boost_post(user_id, message_id) do
            {:ok, _} ->
              updated_posts =
                Enum.map(socket.assigns.posts, fn post ->
                  if post.id == message_id do
                    %{post | share_count: (post.share_count || 0) + 1}
                  else
                    post
                  end
                end)

              {:noreply,
               socket
               |> assign(:posts, updated_posts)
               |> assign(:user_boosts, Map.put(socket.assigns.user_boosts, message_id, true))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    end
  end

  def handle_event("vote_poll", params, socket) do
    if socket.assigns[:current_user] do
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      with {poll_id, _} <- Integer.parse(to_string(poll_id)),
           {option_id, _} <- Integer.parse(to_string(option_id)) do
        case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
          {:ok, _vote} ->
            poll = Elektrine.Repo.get!(Elektrine.Social.Poll, poll_id)
            message_id = poll.message_id

            updated_post =
              Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
              |> Elektrine.Repo.preload(hashtag_post_preloads(), force: true)
              |> Elektrine.Messaging.Message.decrypt_content()

            updated_posts =
              Enum.map(socket.assigns.posts, fn post ->
                if post.id == message_id do
                  updated_post
                else
                  post
                end
              end)

            {:noreply, assign(socket, :posts, updated_posts)}

          {:error, :poll_closed} ->
            {:noreply, put_flash(socket, :error, "This poll has closed")}

          {:error, :invalid_option} ->
            {:noreply, put_flash(socket, :error, "Invalid poll option")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to vote")}
        end
      else
        _ -> {:noreply, put_flash(socket, :error, "Invalid poll vote")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    end
  end

  def handle_event("view_post", %{"message_id" => post_id}, socket) do
    handle_event("navigate_to_post", %{"id" => post_id}, socket)
  end

  def handle_event("navigate_to_embedded_post", %{"id" => post_id}, socket) do
    handle_event("navigate_to_post", %{"id" => post_id}, socket)
  end

  def handle_event("copy_post_link", %{"message_id" => post_id}, socket) do
    link = ElektrineWeb.Endpoint.url() <> "/timeline/post/#{post_id}"

    {:noreply,
     socket |> push_event("copy_to_clipboard", %{text: link}) |> put_flash(:info, "Link copied!")}
  end

  def handle_event("report_post", %{"message_id" => _post_id}, socket) do
    {:noreply, put_flash(socket, :info, "Report feature coming soon")}
  end

  def handle_event("delete_post", %{"message_id" => post_id}, socket) do
    post_id =
      if is_binary(post_id) do
        String.to_integer(post_id)
      else
        post_id
      end

    post = Enum.find(socket.assigns.posts, &(&1.id == post_id))

    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:noreply, put_flash(socket, :error, "You must be signed in")}

      is_nil(post) ->
        {:noreply, put_flash(socket, :error, "Post not found")}

      post.sender_id != socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "You can only delete your own posts")}

      true ->
        case Elektrine.Messaging.Messages.delete_message(post_id, socket.assigns.current_user.id) do
          {:ok, _} ->
            updated_posts = Enum.reject(socket.assigns.posts, &(&1.id == post_id))

            {:noreply,
             socket |> assign(:posts, updated_posts) |> put_flash(:info, "Post deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete post")}
        end
    end
  end

  def handle_event("delete_post_admin", %{"message_id" => post_id}, socket) do
    post_id =
      if is_binary(post_id) do
        String.to_integer(post_id)
      else
        post_id
      end

    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:noreply, put_flash(socket, :error, "You must be signed in")}

      !socket.assigns.current_user.is_admin ->
        {:noreply, put_flash(socket, :error, "Admin only")}

      true ->
        case Elektrine.Messaging.Messages.delete_message(
               post_id,
               socket.assigns.current_user.id,
               true
             ) do
          {:ok, _} ->
            updated_posts = Enum.reject(socket.assigns.posts, &(&1.id == post_id))

            {:noreply,
             socket |> assign(:posts, updated_posts) |> put_flash(:info, "Post deleted by admin")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete post")}
        end
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp get_hashtag_info(hashtag_name) do
    normalized_name = String.downcase(hashtag_name)

    case Elektrine.Repo.get_by(Elektrine.Social.Hashtag, normalized_name: normalized_name) do
      nil ->
        %{name: hashtag_name, use_count: 0, last_used_at: nil}

      hashtag ->
        %{name: hashtag.name, use_count: hashtag.use_count, last_used_at: hashtag.last_used_at}
    end
  end

  defp update_post_in_hashtag_feed(socket, message_id, action) do
    update(socket, :posts, fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          case action do
            :increment_likes -> %{post | like_count: post.like_count + 1}
            :decrement_likes -> %{post | like_count: max(0, post.like_count - 1)}
          end
        else
          post
        end
      end)
    end)
  end

  defp update_user_like_status(socket, message_id, liked) do
    assign(socket, :user_likes, Map.put(socket.assigns.user_likes, message_id, liked))
  end

  defp hashtag_post_preloads do
    Elektrine.Messaging.Messages.timeline_post_preloads()
  end
end
