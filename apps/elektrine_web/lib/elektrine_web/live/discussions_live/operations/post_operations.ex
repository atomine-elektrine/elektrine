defmodule ElektrineWeb.DiscussionsLive.Operations.PostOperations do
  @moduledoc """
  Handles all post-related operations: creating, editing, deleting, pinning, locking posts.
  """

  require Logger

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Messaging, Repo, Social}
  alias ElektrineWeb.DiscussionsLive.Operations.SortHelpers

  # Toggle new post form visibility
  def handle_event("toggle_new_post", _params, socket) do
    if socket.assigns.current_user do
      {:noreply,
       socket
       |> update(:show_new_post, &(!&1))
       |> assign(:new_post_title, "")
       |> assign(:new_post_content, "")}
    else
      {:noreply, notify_error(socket, "You must be signed in to create posts")}
    end
  end

  # Select post type (text, link, image, poll)
  def handle_event("select_post_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:post_type, type)
     |> assign(:link_url, nil)
     |> assign(:link_title, nil)
     |> assign(:new_post_content, "")
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  # Update form fields for validation and character counting
  def handle_event("update_post_form", params, socket) do
    title = Map.get(params, "title", socket.assigns.new_post_title) || ""
    content = Map.get(params, "content", socket.assigns.new_post_content) || ""
    link_url = Map.get(params, "link_url")

    socket =
      socket
      |> assign(:new_post_title, title)
      |> assign(:new_post_content, content)

    # Handle link URL changes - fetch preview if URL changed
    socket =
      if link_url && link_url != "" && link_url != socket.assigns.link_url do
        socket
        |> assign(:link_url, link_url)
        |> maybe_fetch_link_preview(link_url)
      else
        socket
      end

    {:noreply, socket}
  end

  # Handle title updates from phx-keyup
  def handle_event("update_post_title", %{"value" => title}, socket) do
    {:noreply, assign(socket, :new_post_title, title)}
  end

  def handle_event("update_post_title", params, socket) do
    title = Map.get(params, "title", "")
    {:noreply, assign(socket, :new_post_title, title)}
  end

  def handle_event("update_post_content", params, socket) do
    content = Map.get(params, "content", "")
    {:noreply, assign(socket, :new_post_content, content)}
  end

  # Open image upload modal
  def handle_event("open_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, true)}
  end

  # Close image upload modal
  def handle_event("close_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, false)}
  end

  # Validate discussion upload
  def handle_event("validate_discussion_upload", _params, socket) do
    {:noreply, socket}
  end

  # Upload discussion media (images, videos, audio)
  def handle_event("upload_discussion_images", params, socket) do
    user = socket.assigns.current_user

    # Capture alt texts from params
    alt_texts =
      params
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "alt_text_") end)
      |> Enum.map(fn {key, value} ->
        index = key |> String.replace("alt_text_", "") |> String.to_integer()
        {to_string(index), value}
      end)
      |> Map.new()

    # Upload files
    uploaded_files =
      consume_uploaded_entries(socket, :discussion_attachments, fn %{path: path}, entry ->
        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Elektrine.Uploads.upload_discussion_attachment(upload_struct, user.id) do
          {:ok, metadata} ->
            {:ok, metadata.key}

          {:error, _reason} ->
            {:postpone, :error}
        end
      end)

    if Enum.empty?(uploaded_files) do
      {:noreply, notify_error(socket, "Please select files to upload")}
    else
      # Store uploaded URLs and alt texts - they'll be included when creating the post
      {:noreply,
       socket
       |> assign(:show_image_upload_modal, false)
       |> assign(:pending_media_urls, uploaded_files)
       |> assign(:pending_media_alt_texts, alt_texts)
       |> notify_info("#{length(uploaded_files)} file(s) added")}
    end
  end

  # Clear pending media
  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  # Update link URL and fetch metadata
  def handle_event("update_link_url", %{"link_url" => url}, socket) do
    # Only fetch title if URL is valid and title is empty
    updated_socket =
      if String.trim(url) != "" && is_nil(socket.assigns.link_title) do
        case Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(url) do
          metadata when is_map(metadata) ->
            if metadata[:title] && metadata[:title] != "" do
              socket
              |> assign(:link_url, url)
              |> assign(:link_title, metadata[:title])
            else
              assign(socket, :link_url, url)
            end

          _ ->
            assign(socket, :link_url, url)
        end
      else
        assign(socket, :link_url, url)
      end

    {:noreply, updated_socket}
  end

  # Add poll option
  def handle_event("add_poll_option", _params, socket) do
    {:noreply, update(socket, :poll_options, fn options -> options ++ [""] end)}
  end

  # Remove poll option
  def handle_event("remove_poll_option", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update(socket, :poll_options, fn options ->
       List.delete_at(options, index)
     end)}
  end

  # Create discussion post (dispatches to specific type handlers)
  def handle_event("create_discussion_post", params, socket) do
    if socket.assigns.current_user do
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      # Check moderation restrictions before allowing post
      if Elektrine.Messaging.ModerationTools.user_timed_out?(community.id, user_id) do
        # Check if user is timed out
        {:noreply,
         notify_error(socket, "You are currently timed out from posting in this community")}
      else
        # Check slow mode
        case Elektrine.Messaging.ModerationTools.check_slow_mode(community.id, user_id) do
          {:ok, :allowed} ->
            # Auto-join the user to the community when they post (if not already a member)
            if !member?(community.id, user_id) do
              Messaging.add_member_to_conversation(community.id, user_id, "member")
            end

            # Handle different post types
            case socket.assigns.post_type do
              "poll" ->
                create_poll_post(params, socket)

              "link" ->
                create_link_post(params, socket)

              "image" ->
                create_image_post(params, socket)

              # "text"
              _ ->
                create_text_post(params, socket)
            end

          {:error, :slow_mode_active, seconds_remaining} ->
            {:noreply,
             notify_error(
               socket,
               "Please wait #{seconds_remaining} seconds before posting again"
             )}
        end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to create posts")}
    end
  end

  # View discussion post
  def handle_event("view_discussion", %{"message_id" => message_id}, socket) do
    post = Enum.find(socket.assigns.discussion_posts, &(&1.id == String.to_integer(message_id)))

    if post do
      url = generate_discussion_url(socket.assigns.community, post)
      {:noreply, push_navigate(socket, to: url)}
    else
      {:noreply, socket}
    end
  end

  # Copy discussion link to clipboard
  def handle_event("copy_discussion_link", %{"message_id" => message_id}, socket) do
    post = Enum.find(socket.assigns.discussion_posts, &(&1.id == String.to_integer(message_id)))

    if post do
      url =
        "#{ElektrineWeb.Endpoint.url()}#{generate_discussion_url(socket.assigns.community, post)}"

      {:noreply,
       socket
       |> push_event("copy_to_clipboard", %{text: url})
       |> put_flash(:info, "Link copied to clipboard")}
    else
      {:noreply, socket}
    end
  end

  # Delete discussion (by author)
  def handle_event("delete_discussion", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = Enum.find(socket.assigns.discussion_posts, &(&1.id == message_id))

    if post && post.sender_id == socket.assigns.current_user.id do
      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          updated_posts = Enum.reject(socket.assigns.discussion_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:discussion_posts, updated_posts)
           |> put_flash(:info, "Discussion deleted successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete discussion")}
      end
    else
      {:noreply, notify_error(socket, "You can only delete your own discussions")}
    end
  end

  # Delete discussion (by admin)
  def handle_event("delete_discussion_admin", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user && socket.assigns.current_user.is_admin do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id, true) do
        {:ok, _} ->
          updated_posts = Enum.reject(socket.assigns.discussion_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:discussion_posts, updated_posts)
           |> put_flash(:info, "Discussion deleted by admin")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete discussion")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Delete post (by moderator)
  def handle_event("delete_post_mod", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          # Remove from both regular and pinned posts
          updated_posts = Enum.reject(socket.assigns.discussion_posts, &(&1.id == message_id))
          updated_pinned = Enum.reject(socket.assigns.pinned_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:discussion_posts, updated_posts)
           |> assign(:pinned_posts, updated_pinned)
           |> put_flash(:info, "Post deleted successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Pin post
  def handle_event("pin_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Messaging.pin_message(message_id, socket.assigns.current_user.id) do
        {:ok, _pinned_message} ->
          pinned_posts = load_pinned_posts(socket.assigns.community.id)

          {:noreply,
           socket
           |> assign(:pinned_posts, pinned_posts)
           |> put_flash(:info, "Post pinned to the community header.")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to pin post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Unpin post
  def handle_event("unpin_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Messaging.unpin_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          pinned_posts = load_pinned_posts(socket.assigns.community.id)

          {:noreply,
           socket
           |> assign(:pinned_posts, pinned_posts)
           |> put_flash(:info, "Post removed from pinned threads.")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unpin post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Set pinned thread role (start here / recurring)
  def handle_event("set_pin_role", %{"message_id" => message_id, "role" => role}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)
      normalized_role = normalize_pin_role(role)

      if Enum.any?(socket.assigns.pinned_posts, &(&1.id == message_id)) do
        if normalized_role in ["start_here", "recurring"] do
          clear_pin_role_from_other_posts(
            socket.assigns.pinned_posts,
            message_id,
            normalized_role
          )
        end

        with %Elektrine.Messaging.Message{} = message <-
               Repo.get(Elektrine.Messaging.Message, message_id),
             {:ok, _updated} <-
               Messaging.update_message(message, %{
                 media_metadata:
                   update_pin_role_metadata(message.media_metadata || %{}, normalized_role)
               }) do
          pinned_posts = load_pinned_posts(socket.assigns.community.id)

          success_message =
            case normalized_role do
              "start_here" -> "Pinned thread labeled as Start Here."
              "recurring" -> "Pinned thread labeled as Recurring."
              _ -> "Pinned thread label cleared."
            end

          {:noreply,
           socket
           |> assign(:pinned_posts, pinned_posts)
           |> put_flash(:info, success_message)}
        else
          _ -> {:noreply, notify_error(socket, "Couldn't update pinned thread label")}
        end
      else
        {:noreply, notify_error(socket, "Pin this post first, then assign a thread role")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Lock thread
  def handle_event("lock_thread", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Elektrine.Messaging.ModerationTools.lock_thread(
             message_id,
             socket.assigns.current_user.id,
             "Locked by moderator"
           ) do
        {:ok, _} ->
          # Reload posts to show lock status
          posts =
            SortHelpers.load_posts(socket.assigns.community.id, socket.assigns.sort_by, limit: 20)

          # Reload moderation log
          mod_log =
            Elektrine.Messaging.ModerationTools.get_moderation_log(socket.assigns.community.id,
              limit: 50
            )

          {:noreply,
           socket
           |> assign(:discussion_posts, posts)
           |> assign(:mod_log, mod_log)
           |> notify_info("Thread locked")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to lock thread")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Unlock thread
  def handle_event("unlock_thread", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Elektrine.Messaging.ModerationTools.unlock_thread(
             message_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          # Reload posts to show lock status
          posts =
            SortHelpers.load_posts(socket.assigns.community.id, socket.assigns.sort_by, limit: 20)

          # Reload moderation log
          mod_log =
            Elektrine.Messaging.ModerationTools.get_moderation_log(socket.assigns.community.id,
              limit: 50
            )

          {:noreply,
           socket
           |> assign(:discussion_posts, posts)
           |> assign(:mod_log, mod_log)
           |> notify_info("Thread unlocked")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unlock thread")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Show reply form
  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user do
      message_id = String.to_integer(message_id)
      reply_to_post = Enum.find(socket.assigns.discussion_posts, &(&1.id == message_id))

      {:noreply,
       socket
       |> assign(:reply_to_post, reply_to_post)
       |> assign(:reply_content, "")}
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  # Cancel reply
  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_post, nil)
     |> assign(:reply_content, "")}
  end

  # Update reply content
  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  # Create reply
  def handle_event("create_reply", %{"content" => content}, socket) do
    if socket.assigns.current_user do
      # Anyone logged in can reply
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      # Auto-join if not already a member
      if !member?(community.id, user_id) do
        Messaging.add_member_to_conversation(community.id, user_id, "member")
      end

      if String.trim(content) == "" do
        {:noreply, notify_error(socket, "Reply cannot be empty")}
      else
        case Messaging.create_text_message(
               community.id,
               user_id,
               content,
               socket.assigns.reply_to_post.id
             ) do
          {:ok, reply_message} ->
            # Create notification for discussion reply
            parent_post = socket.assigns.reply_to_post

            if parent_post.sender_id != user_id do
              # Check if user wants to be notified about discussion replies
              parent_author = Elektrine.Accounts.get_user!(parent_post.sender_id)

              if Map.get(parent_author, :notify_on_discussion_reply, true) do
                Elektrine.Notifications.create_notification(%{
                  user_id: parent_post.sender_id,
                  actor_id: user_id,
                  type: "discussion_reply",
                  title:
                    "@#{socket.assigns.current_user.handle || socket.assigns.current_user.username} replied to your discussion post",
                  body: String.slice(content, 0, 100),
                  url:
                    "/discussions/#{community.name}/post/#{parent_post.id}#reply-#{reply_message.id}",
                  source_type: "message",
                  source_id: reply_message.id,
                  priority: "normal"
                })
              end
            end

            # Process mentions in the reply
            mentions =
              Regex.scan(~r/@(\w+)/, content)
              |> Enum.map(fn [_, username] -> username end)
              |> Enum.uniq()

            sender = socket.assigns.current_user

            Enum.each(mentions, fn username ->
              case Elektrine.Accounts.get_user_by_username_or_handle(username) do
                nil ->
                  :ok

                mentioned_user ->
                  if mentioned_user.id != user_id && mentioned_user.id != parent_post.sender_id do
                    # Check if user wants to be notified about mentions
                    notify_pref = Map.get(mentioned_user, :notify_on_mention, true)

                    if notify_pref do
                      Elektrine.Notifications.create_notification(%{
                        user_id: mentioned_user.id,
                        actor_id: user_id,
                        type: "mention",
                        title: "@#{sender.handle || sender.username} mentioned you",
                        body: "You were mentioned in a discussion reply",
                        url:
                          "/discussions/#{community.name}/post/#{parent_post.id}#reply-#{reply_message.id}",
                        source_type: "message",
                        source_id: reply_message.id,
                        priority: "normal"
                      })
                    end
                  end
              end
            end)

            # Update reply count for the parent post
            parent_post_id = socket.assigns.reply_to_post.id

            updated_posts =
              Enum.map(socket.assigns.discussion_posts, fn post ->
                if post.id == parent_post_id do
                  %{post | reply_count: (post.reply_count || 0) + 1}
                else
                  post
                end
              end)

            # Track trust level activity - discussion replies
            Task.start(fn ->
              # Track reply creation for the person replying
              Elektrine.Accounts.TrustLevel.increment_stat(user_id, :replies_created)

              # Track reply received for the person being replied to
              if parent_post.sender_id != user_id do
                Elektrine.Accounts.TrustLevel.increment_stat(
                  parent_post.sender_id,
                  :replies_received
                )
              end
            end)

            {:noreply,
             socket
             |> assign(:reply_content, "")
             |> assign(:reply_to_post, nil)
             |> assign(:discussion_posts, updated_posts)
             |> put_flash(:info, "Reply posted!")}

          {:error, _error} ->
            {:noreply, notify_error(socket, "Failed to post reply")}
        end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  # Share to timeline
  def handle_event("share_to_timeline", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user do
      message_id = String.to_integer(message_id)

      case Social.share_to_timeline(
             message_id,
             socket.assigns.current_user.id,
             visibility: "followers",
             comment: "Interesting discussion from #{socket.assigns.community.name}:"
           ) do
        {:ok, _timeline_post} ->
          {:noreply,
           socket
           |> put_flash(:info, "Discussion shared to your timeline!")
           |> push_navigate(to: ~p"/timeline")}

        {:error, :not_found} ->
          {:noreply, notify_error(socket, "Discussion not found")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to share discussion")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to share")}
    end
  end

  # Private helper functions

  defp create_text_post(params, socket) do
    content = params["content"]
    title = params["title"]
    trimmed_content = String.trim(content || "")
    trimmed_title = String.trim(title || "")

    cond do
      trimmed_title == "" ->
        {:noreply, notify_error(socket, "Title is required")}

      trimmed_content == "" ->
        {:noreply, notify_error(socket, "Content cannot be empty")}

      true ->
        case Elektrine.Messaging.create_text_message(
               socket.assigns.community.id,
               socket.assigns.current_user.id,
               content,
               nil,
               skip_broadcast: true
             ) do
          {:ok, message} ->
            finalize_discussion_post(message, params, title, false, socket)

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to create post")}
        end
    end
  end

  defp create_link_post(params, socket) do
    title = String.trim(params["title"] || "")
    link_url = String.trim(params["link_url"] || "")

    cond do
      title == "" ->
        {:noreply, notify_error(socket, "Title is required")}

      link_url == "" ->
        {:noreply, notify_error(socket, "Link URL is required")}

      !String.starts_with?(link_url, ["http://", "https://"]) ->
        {:noreply,
         notify_error(socket, "Link must be a valid URL starting with http:// or https://")}

      true ->
        # Create with minimal content (URL will be in primary_url field)
        case Elektrine.Messaging.create_text_message(
               socket.assigns.community.id,
               socket.assigns.current_user.id,
               # Store URL in content too for search/preview
               link_url,
               nil,
               skip_broadcast: true
             ) do
          {:ok, message} ->
            # Update with link-specific attributes
            updated_attrs =
              Map.merge(
                base_discussion_attrs(params, title),
                %{post_type: "link", primary_url: link_url}
              )

            case message
                 |> Elektrine.Messaging.Message.changeset(updated_attrs)
                 |> Repo.update() do
              {:ok, updated_message} ->
                complete_post_creation(updated_message, params["content"], socket)

              {:error, _} ->
                {:noreply, notify_error(socket, "Failed to create link post")}
            end

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to create post")}
        end
    end
  end

  defp create_image_post(params, socket) do
    title = String.trim(params["title"] || "")
    # Optional caption
    content = params["content"] || ""
    media_urls = socket.assigns.pending_media_urls
    alt_texts = Map.get(socket.assigns, :pending_media_alt_texts, %{})

    cond do
      title == "" ->
        {:noreply, notify_error(socket, "Title is required")}

      Enum.empty?(media_urls) ->
        {:noreply, notify_error(socket, "Please upload at least one media file")}

      true ->
        # Create as media message type
        case Elektrine.Messaging.create_text_message(
               socket.assigns.community.id,
               socket.assigns.current_user.id,
               content,
               nil,
               skip_broadcast: true
             ) do
          {:ok, message} ->
            # Build media metadata with alt texts
            media_metadata =
              if map_size(alt_texts) > 0 do
                %{"alt_texts" => alt_texts}
              else
                %{}
              end

            # Update with media-specific attributes
            updated_attrs =
              Map.merge(
                base_discussion_attrs(params, title),
                %{
                  post_type: "discussion",
                  message_type: "image",
                  media_urls: media_urls,
                  media_metadata: media_metadata
                }
              )

            case message
                 |> Elektrine.Messaging.Message.changeset(updated_attrs)
                 |> Repo.update() do
              {:ok, updated_message} ->
                complete_post_creation(updated_message, content, socket)

              {:error, _} ->
                {:noreply, notify_error(socket, "Failed to create media post")}
            end

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to create post")}
        end
    end
  end

  defp create_poll_post(params, socket) do
    title = String.trim(params["title"] || "")
    poll_question = String.trim(params["poll_question"] || "")

    # Collect poll options from params (they're named poll_option_0, poll_option_1, etc.)
    poll_options =
      params
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "poll_option_") end)
      |> Enum.sort_by(fn {key, _value} ->
        key |> String.replace("poll_option_", "") |> String.to_integer()
      end)
      |> Enum.map(fn {_key, value} -> String.trim(value) end)
      |> Enum.reject(&(&1 == ""))

    cond do
      title == "" ->
        {:noreply, notify_error(socket, "Title is required")}

      poll_question == "" ->
        {:noreply, notify_error(socket, "Poll question is required")}

      String.length(poll_question) < 3 ->
        {:noreply, notify_error(socket, "Poll question must be at least 3 characters")}

      String.length(poll_question) > 300 ->
        {:noreply, notify_error(socket, "Poll question must be at most 300 characters")}

      length(poll_options) < 2 ->
        {:noreply, notify_error(socket, "Poll must have at least 2 options")}

      Enum.any?(poll_options, fn opt -> String.length(opt) > 200 end) ->
        {:noreply, notify_error(socket, "Poll options must be at most 200 characters")}

      true ->
        # Create post first with placeholder content
        case Elektrine.Messaging.create_text_message(
               socket.assigns.community.id,
               socket.assigns.current_user.id,
               # Placeholder content
               "Poll",
               nil,
               skip_broadcast: true
             ) do
          {:ok, message} ->
            # Update with poll-specific attributes
            updated_attrs =
              Map.merge(
                base_discussion_attrs(params, title),
                # Clear placeholder
                %{post_type: "poll", content: ""}
              )

            case message
                 |> Elektrine.Messaging.Message.changeset(updated_attrs)
                 |> Repo.update() do
              {:ok, updated_message} ->
                # Create poll
                poll_duration_days = String.to_integer(params["poll_duration_days"] || "7")
                allow_multiple = params["poll_allow_multiple"] == "on"

                closes_at =
                  if poll_duration_days > 0 do
                    DateTime.add(DateTime.utc_now(), poll_duration_days * 24 * 60 * 60, :second)
                  else
                    nil
                  end

                case Social.create_poll(
                       updated_message.id,
                       poll_question,
                       poll_options,
                       closes_at: closes_at,
                       allow_multiple: allow_multiple
                     ) do
                  {:ok, _poll} ->
                    complete_post_creation(updated_message, "", socket)

                  {:error, reason} ->
                    # Rollback - delete the message
                    Repo.delete(updated_message)
                    error_message = format_poll_error(reason)
                    {:noreply, notify_error(socket, error_message)}
                end

              {:error, _} ->
                {:noreply, notify_error(socket, "Failed to create poll post")}
            end

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to create post")}
        end
    end
  end

  defp base_discussion_attrs(params, title) do
    flair_id =
      case params["flair_id"] do
        "" -> nil
        nil -> nil
        id -> String.to_integer(id)
      end

    %{
      title: title,
      auto_title: false,
      post_type: "discussion",
      visibility: "public",
      flair_id: flair_id
    }
  end

  defp finalize_discussion_post(message, params, title, is_auto_title, socket) do
    flair_id =
      case params["flair_id"] do
        "" -> nil
        nil -> nil
        id -> String.to_integer(id)
      end

    updated_attrs = %{
      title: title,
      auto_title: is_auto_title,
      post_type: "discussion",
      visibility: "public",
      flair_id: flair_id
    }

    case message
         |> Elektrine.Messaging.Message.changeset(updated_attrs)
         |> Repo.update() do
      {:ok, updated_message} ->
        complete_post_creation(updated_message, params["content"], socket)

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to create post")}
    end
  end

  defp complete_post_creation(message, content, socket) do
    # Check auto-mod rules
    case Elektrine.Messaging.ModerationTools.check_auto_mod_rules(
           message.conversation_id,
           content
         ) do
      {:blocked, _rule} ->
        # Auto-remove the post
        Repo.delete(message)
        {:noreply, notify_error(socket, "Post blocked by auto-moderation rules")}

      {:hold, _rule} ->
        # Hold for review
        {:ok, _pending_message} =
          message
          |> Elektrine.Messaging.Message.changeset(%{approval_status: "pending"})
          |> Repo.update()

        # Reload pending posts to include this one
        pending_posts =
          if socket.assigns.is_moderator do
            Elektrine.Messaging.ModerationTools.list_pending_posts(socket.assigns.community.id)
            |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)
          else
            socket.assigns.pending_posts
          end

        {:noreply,
         socket
         |> assign(:show_new_post, false)
         |> assign(:post_type, "text")
         |> assign(:poll_options, ["", ""])
         |> assign(:pending_posts, pending_posts)
         |> notify_info("Post is pending moderator approval")}

      {:flagged, rule} ->
        # Flag for moderator review but allow post to be visible
        # Mark the message as flagged by storing the rule name in metadata
        {:ok, flagged_message} =
          message
          |> Elektrine.Messaging.Message.changeset(%{
            media_metadata:
              Map.put(message.media_metadata || %{}, "automod_flagged", %{
                "rule_name" => rule.name,
                "rule_id" => rule.id,
                "flagged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              })
          })
          |> Repo.update()

        # Continue with normal approval flow
        continue_post_creation(flagged_message, content, socket)

      _ ->
        continue_post_creation(message, content, socket)
    end
  end

  defp continue_post_creation(message, content, socket) do
    # Check if approval mode is enabled
    needs_approval =
      Elektrine.Messaging.ModerationTools.needs_approval?(
        message.conversation_id,
        socket.assigns.current_user.id
      )

    message =
      if needs_approval do
        {:ok, updated} =
          message
          |> Elektrine.Messaging.Message.changeset(%{approval_status: "pending"})
          |> Repo.update()

        updated
      else
        # Auto-approve
        {:ok, updated} =
          message
          |> Elektrine.Messaging.Message.changeset(%{approval_status: "approved"})
          |> Repo.update()

        updated
      end

    # Extract and process hashtags
    hashtags = Elektrine.Social.HashtagExtractor.extract_hashtags(content || "")

    if hashtags != [] do
      Elektrine.Social.HashtagExtractor.process_hashtags_for_message(message, hashtags)
    end

    # Process mentions in the discussion post
    mentions =
      Regex.scan(~r/@(\w+)/, content || "")
      |> Enum.map(fn [_, username] -> username end)
      |> Enum.uniq()

    sender = socket.assigns.current_user

    Enum.each(mentions, fn username ->
      case Elektrine.Accounts.get_user_by_username_or_handle(username) do
        nil ->
          :ok

        mentioned_user ->
          if mentioned_user.id != sender.id do
            # Check if user wants to be notified about mentions
            notify_pref = Map.get(mentioned_user, :notify_on_mention, true)

            if notify_pref do
              Elektrine.Notifications.create_notification(%{
                user_id: mentioned_user.id,
                actor_id: sender.id,
                type: "mention",
                title: "@#{sender.handle || sender.username} mentioned you",
                body: "You were mentioned in a discussion post",
                url: "/discussions/#{socket.assigns.community.name}/post/#{message.id}",
                source_type: "message",
                source_id: message.id,
                priority: "normal"
              })
            end
          end
      end
    end)

    # Update slow mode timestamp
    Elektrine.Messaging.ModerationTools.update_post_timestamp(
      message.conversation_id,
      socket.assigns.current_user.id
    )

    # Preload ALL associations
    message =
      Repo.preload(
        message,
        [
          :sender,
          :link_preview,
          :hashtags,
          :replies,
          :reactions,
          :flair,
          :poll,
          sender: :profile,
          poll: [options: []]
        ],
        force: true
      )

    # Broadcast only if approved
    if message.approval_status == "approved" do
      # Broadcast to discussion-specific channel (NOT conversation channel used by chat)
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "discussion:#{message.conversation_id}",
        {:new_message, message}
      )

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "discussions:all",
        {:new_discussion_post, message}
      )

      # Federate to ActivityPub if community is public
      Elektrine.Async.run(fn ->
        case Elektrine.Messaging.Conversations.get_conversation_basic(message.conversation_id) do
          {:ok, community_conv} ->
            if community_conv.is_public do
              Elektrine.ActivityPub.Outbox.federate_community_post(message, community_conv)
            end

          _ ->
            :ok
        end
      end)
    end

    success_message =
      if needs_approval do
        "Post submitted. A moderator will review it shortly."
      else
        "Post published in this community."
      end

    # Track trust level activity - discussion post and topic creation
    Elektrine.Async.run(fn ->
      Elektrine.Accounts.TrustLevel.increment_stat(socket.assigns.current_user.id, :posts_created)

      Elektrine.Accounts.TrustLevel.increment_stat(
        socket.assigns.current_user.id,
        :topics_created
      )
    end)

    {:noreply,
     socket
     |> assign(:show_new_post, false)
     # Reset to default
     |> assign(:post_type, "text")
     # Reset poll option count
     |> assign(:poll_options, ["", ""])
     # Reset uploaded media
     |> assign(:pending_media_urls, [])
     # Reset alt texts
     |> assign(:pending_media_alt_texts, %{})
     |> put_flash(:info, success_message)}
  end

  defp generate_discussion_url(community, post) do
    community_name = community.name
    # Always use SEO-friendly URL with slug (falls back to just ID if no title)
    slug = Elektrine.Utils.Slug.discussion_url_slug(post.id, post.title)
    ~p"/communities/#{community_name}/post/#{slug}"
  end

  defp member?(community_id, user_id) do
    import Ecto.Query

    Repo.exists?(
      from cm in Elektrine.Messaging.ConversationMember,
        where:
          cm.conversation_id == ^community_id and
            cm.user_id == ^user_id and
            is_nil(cm.left_at)
    )
  end

  defp format_poll_error(reason) when is_binary(reason), do: reason

  defp format_poll_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    # Format errors into a readable string
    errors
    |> Enum.map(fn {field, messages} ->
      "#{field}: #{Enum.join(messages, ", ")}"
    end)
    |> Enum.map_join("; ", & &1)
    |> case do
      "" -> "Failed to create poll"
      msg -> "Failed to create poll: #{msg}"
    end
  end

  defp format_poll_error(_), do: "Failed to create poll"

  defp load_pinned_posts(community_id) do
    Messaging.list_pinned_messages(community_id)
    |> Repo.preload([
      :sender,
      :flair,
      :poll,
      :link_preview,
      sender: :profile,
      shared_message: [sender: [:profile], conversation: []],
      poll: [options: []]
    ])
    |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)
  end

  defp normalize_pin_role(role) when role in ["start_here", "recurring", "none"], do: role
  defp normalize_pin_role(_), do: "none"

  defp update_pin_role_metadata(metadata, "none"), do: Map.delete(metadata, "community_pin_type")
  defp update_pin_role_metadata(metadata, role), do: Map.put(metadata, "community_pin_type", role)

  defp clear_pin_role_from_other_posts(pinned_posts, message_id, role) do
    Enum.each(pinned_posts, fn post ->
      if post.id != message_id &&
           get_in(post.media_metadata || %{}, ["community_pin_type"]) == role do
        case Repo.get(Elektrine.Messaging.Message, post.id) do
          %Elektrine.Messaging.Message{} = message ->
            cleaned_metadata = Map.delete(message.media_metadata || %{}, "community_pin_type")
            _ = Messaging.update_message(message, %{media_metadata: cleaned_metadata})

          _ ->
            :ok
        end
      end
    end)
  end

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end

  defp notify_info(socket, message) do
    put_flash(socket, :info, message)
  end

  defp maybe_fetch_link_preview(socket, url) do
    # Only fetch if URL looks valid and we don't already have a title
    if (String.starts_with?(url, "http://") || String.starts_with?(url, "https://")) &&
         is_nil(socket.assigns.link_title) do
      case Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(url) do
        metadata when is_map(metadata) ->
          if metadata[:title] && metadata[:title] != "" do
            assign(socket, :link_title, metadata[:title])
          else
            socket
          end

        _ ->
          socket
      end
    else
      socket
    end
  end
end
