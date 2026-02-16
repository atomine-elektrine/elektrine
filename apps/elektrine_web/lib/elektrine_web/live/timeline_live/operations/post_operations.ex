defmodule ElektrineWeb.TimelineLive.Operations.PostOperations do
  @moduledoc """
  Handles post-related operations for the timeline LiveView.
  Includes post creation, deletion, filtering, and composer interactions.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Social
  alias Elektrine.Social.Drafts
  alias Elektrine.Messaging
  alias Elektrine.Timeline.RateLimiter, as: TimelineRateLimiter
  alias ElektrineWeb.TimelineLive.Operations.Helpers

  # Toggles the post composer visibility.
  def handle_event("toggle_post_composer", _params, socket) do
    {:noreply,
     socket
     |> update(:show_post_composer, &(!&1))
     |> assign(:new_post_title, nil)
     |> assign(:new_post_content, "")
     |> assign(:new_post_content_warning, nil)
     |> assign(:new_post_sensitive, false)
     |> assign(:show_cw_input, false)
     |> assign(:editing_draft_id, nil)
     |> assign(:draft_auto_saved, false)
     |> assign(:draft_saving, false)}
  end

  # Updates the post title.
  def handle_event("update_post_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, :new_post_title, title)}
  end

  # Updates the post visibility setting.
  def handle_event("update_visibility", %{"visibility" => visibility}, socket) do
    {:noreply, assign(socket, :new_post_visibility, visibility)}
  end

  # Toggles the content warning input field.
  def handle_event("toggle_content_warning", _params, socket) do
    {:noreply,
     socket
     |> update(:show_cw_input, &(!&1))
     |> assign(
       :new_post_content_warning,
       if(socket.assigns.show_cw_input, do: nil, else: socket.assigns.new_post_content_warning)
     )}
  end

  # Updates the content warning text.
  def handle_event("update_content_warning", %{"cw" => cw}, socket) do
    {:noreply,
     socket
     |> assign(:new_post_content_warning, cw)
     |> assign(:new_post_sensitive, cw && String.trim(cw) != "")}
  end

  # Updates the post content and automatically fetches link preview for title.
  def handle_event("update_post_content", %{"content" => content}, socket) do
    urls = Elektrine.Social.LinkPreviewFetcher.extract_urls(content)

    current_title = socket.assigns.new_post_title
    should_fetch_title = (is_nil(current_title) || current_title == "") && urls != []

    updated_socket =
      if should_fetch_title do
        metadata = Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(hd(urls))

        if metadata[:title] && metadata[:title] != "" do
          assign(socket, :new_post_title, metadata[:title])
        else
          socket
        end
      else
        socket
      end

    {:noreply, assign(updated_socket, :new_post_content, content)}
  end

  # Auto-saves draft when form changes (debounced from template)
  def handle_event("autosave_draft", params, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, socket}
    else
      content = params["content"] || socket.assigns.new_post_content || ""
      title = params["title"] || socket.assigns.new_post_title
      cw = params["cw"]

      # Only auto-save if there's some content
      has_content =
        content != "" || title != nil || !Enum.empty?(socket.assigns.pending_media_urls)

      if !has_content do
        {:noreply, socket}
      else
        # Update local state first
        socket =
          socket
          |> assign(:new_post_content, content)
          |> assign(:new_post_title, if(title == "", do: nil, else: title))
          |> assign(:new_post_content_warning, cw)
          |> assign(:new_post_sensitive, cw && String.trim(cw || "") != "")
          |> assign(:draft_saving, true)

        # Auto-fetch link preview for title if needed
        urls = Elektrine.Social.LinkPreviewFetcher.extract_urls(content)
        current_title = socket.assigns.new_post_title

        socket =
          if (is_nil(current_title) || current_title == "") && urls != [] do
            metadata = Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(hd(urls))

            if metadata[:title] && metadata[:title] != "" do
              assign(socket, :new_post_title, metadata[:title])
            else
              socket
            end
          else
            socket
          end

        # Save or update draft
        visibility = socket.assigns.new_post_visibility
        media_urls = socket.assigns.pending_media_urls
        alt_texts = socket.assigns.pending_media_alt_texts || %{}
        draft_id = socket.assigns[:editing_draft_id]

        opts = [
          content: content,
          title: socket.assigns.new_post_title,
          visibility: visibility,
          media_urls: media_urls,
          alt_texts: alt_texts,
          content_warning: socket.assigns.new_post_content_warning
        ]

        opts = if draft_id, do: Keyword.put(opts, :draft_id, draft_id), else: opts

        case Drafts.save_draft(user.id, opts) do
          {:ok, draft} ->
            # Update the drafts list to reflect the new/updated draft
            updated_drafts =
              socket.assigns.user_drafts
              |> Kernel.||([])
              |> Enum.reject(&(&1.id == draft.id))
              |> then(&[draft | &1])

            {:noreply,
             socket
             |> assign(:editing_draft_id, draft.id)
             |> assign(:draft_auto_saved, true)
             |> assign(:draft_saving, false)
             |> assign(:user_drafts, updated_drafts)}

          {:error, _changeset} ->
            {:noreply, assign(socket, :draft_saving, false)}
        end
      end
    end
  end

  # Loads queued posts into the timeline.
  def handle_event("load_queued_posts", _params, socket) do
    queued = socket.assigns.queued_posts

    if Enum.empty?(queued) do
      {:noreply, socket}
    else
      unique_queued = Enum.uniq_by(queued, & &1.id)
      existing_ids = socket.assigns.timeline_posts |> Enum.map(& &1.id) |> MapSet.new()
      new_posts = Enum.reject(unique_queued, fn post -> MapSet.member?(existing_ids, post.id) end)

      updated_socket =
        socket
        |> update(:timeline_posts, fn posts -> new_posts ++ posts end)
        |> assign(:queued_posts, [])
        |> assign(:recently_loaded_post_ids, Enum.map(new_posts, & &1.id))
        |> assign(:recently_loaded_count, length(new_posts))
        |> Helpers.apply_timeline_filter()

      {:noreply, updated_socket}
    end
  end

  # Creates a new timeline post.
  def handle_event(
        "create_post",
        %{"content" => content, "visibility" => visibility} = params,
        socket
      ) do
    user = socket.assigns.current_user
    has_content = String.trim(content) != ""
    has_attachments = !Enum.empty?(socket.assigns.pending_media_urls)

    if !has_content && !has_attachments do
      {:noreply, put_flash(socket, :error, "Post cannot be empty")}
    else
      title =
        case params["title"] do
          nil -> nil
          "" -> nil
          t -> String.trim(t)
        end

      uploaded_files = socket.assigns.pending_media_urls
      alt_texts = socket.assigns.pending_media_alt_texts || %{}

      post_opts = [visibility: visibility, media_urls: uploaded_files]
      post_opts = if title, do: Keyword.put(post_opts, :title, title), else: post_opts

      post_opts =
        if !Enum.empty?(alt_texts),
          do: Keyword.put(post_opts, :alt_texts, alt_texts),
          else: post_opts

      post_opts =
        if socket.assigns.new_post_content_warning,
          do: Keyword.put(post_opts, :content_warning, socket.assigns.new_post_content_warning),
          else: post_opts

      post_opts =
        if socket.assigns.new_post_sensitive,
          do: Keyword.put(post_opts, :sensitive, true),
          else: post_opts

      case Social.create_timeline_post(user.id, content, post_opts) do
        {:ok, real_post} ->
          # Delete the auto-saved draft if one exists
          if socket.assigns[:editing_draft_id] do
            Task.start(fn ->
              Drafts.delete_draft(socket.assigns.editing_draft_id, user.id)
            end)
          end

          Task.start(fn ->
            Elektrine.Accounts.TrustLevel.increment_stat(user.id, :posts_created)
            Elektrine.Accounts.TrustLevel.increment_stat(user.id, :topics_created)
          end)

          {:noreply,
           socket
           |> assign(:new_post_content, "")
           |> assign(:new_post_title, nil)
           |> assign(:new_post_content_warning, nil)
           |> assign(:new_post_sensitive, false)
           |> assign(:show_cw_input, false)
           |> assign(:show_post_composer, false)
           |> assign(:pending_media_urls, [])
           |> assign(:pending_media_alt_texts, %{})
           |> assign(:editing_draft_id, nil)
           |> assign(:draft_auto_saved, false)
           |> assign(:draft_saving, false)
           |> assign(:recently_loaded_post_ids, [])
           |> assign(:recently_loaded_count, 0)
           |> update(:timeline_posts, fn posts -> [real_post | posts] end)
           |> Helpers.apply_timeline_filter()
           |> put_flash(:info, "Post published to your timeline.")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Couldn't publish your post. Please try again.")}
      end
    end
  end

  # Deletes a post (user deleting their own post).
  def handle_event("delete_post", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

    if post && post.sender_id == socket.assigns.current_user.id do
      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _deleted_message} ->
          updated_posts = Enum.reject(socket.assigns.timeline_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:timeline_posts, updated_posts)
           |> Helpers.apply_timeline_filter()
           |> put_flash(:info, "Post deleted successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete post")}
      end
    else
      {:noreply, put_flash(socket, :error, "You can only delete your own posts")}
    end
  end

  # Deletes a post (admin action).
  def handle_event("delete_post_admin", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user && socket.assigns.current_user.is_admin do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id, true) do
        {:ok, _deleted_message} ->
          updated_posts = Enum.reject(socket.assigns.timeline_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:timeline_posts, updated_posts)
           |> Helpers.apply_timeline_filter()
           |> put_flash(:info, "Post deleted successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete post")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # Navigates to post detail view.
  def handle_event("view_post", %{"message_id" => message_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message_id}")}
  end

  # Copies post link to clipboard.
  def handle_event("copy_post_link", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

    if post do
      post_url = "#{ElektrineWeb.Endpoint.url()}/timeline/post/#{message_id}"

      {:noreply,
       socket
       |> push_event("copy_to_clipboard", %{text: post_url})
       |> put_flash(:info, "Link copied to clipboard")}
    else
      {:noreply, socket}
    end
  end

  # Opens the report modal for a post.
  def handle_event("report_post", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

    if post do
      report_metadata = %{
        "sender_id" => post.sender_id,
        "content_preview" => String.slice(post.content || "", 0, 100),
        "source" => "timeline"
      }

      {:noreply,
       socket
       |> assign(:show_report_modal, true)
       |> assign(:report_type, "message")
       |> assign(:report_id, message_id)
       |> assign(:report_metadata, report_metadata)}
    else
      {:noreply, socket}
    end
  end

  # Loads more posts for infinite scroll.
  def handle_event("load_more_posts", _params, socket) do
    # Skip if already loading or we've reached the end
    if socket.assigns.loading_more || socket.assigns[:no_more_posts] do
      {:noreply, socket}
    else
      send(self(), :load_more_timeline_posts)
      {:noreply, assign(socket, :loading_more, true)}
    end
  end

  # Triggers load more when infinite scroll is detected.
  def handle_event("load-more", _params, socket) do
    # Skip if loading or we've reached the end
    if socket.assigns.loading_more || socket.assigns[:no_more_posts] do
      {:noreply, socket}
    else
      handle_event("load_more_posts", %{}, socket)
    end
  end

  # Filters timeline by content type (posts, replies, media, etc).
  def handle_event("filter_timeline", %{"filter" => filter}, socket) do
    current_view = socket.assigns.timeline_filter || "all"

    if filter == current_view do
      {:noreply, assign(socket, :filter_dropdown_open, false)}
    else
      path = ~p"/timeline?filter=#{socket.assigns.current_filter}&view=#{filter}"

      cond do
        special_timeline_view?(filter) ->
          load_ref = System.unique_integer([:positive, :monotonic])
          send(self(), {:load_view_data, load_ref, socket.assigns.current_filter, filter})

          {:noreply,
           socket
           |> assign(:filter_dropdown_open, false)
           |> assign(:timeline_load_ref, load_ref)
           |> assign(:timeline_filter, filter)
           |> assign(:loading_timeline, Enum.empty?(socket.assigns.timeline_posts))
           |> assign(:loading_more, false)
           |> assign(:no_more_posts, false)
           |> push_patch(to: path)}

        special_timeline_view?(current_view) &&
            Enum.empty?(Map.get(socket.assigns, :base_timeline_posts, [])) ->
          {:noreply,
           socket
           |> assign(:filter_dropdown_open, false)
           |> push_patch(to: path)}

        true ->
          updated_socket =
            socket
            |> assign(:filter_dropdown_open, false)
            |> assign(:timeline_filter, filter)
            |> assign(:loading_timeline, false)
            |> maybe_restore_base_timeline(current_view)
            |> Helpers.apply_timeline_filter()

          {:noreply, push_patch(updated_socket, to: path)}
      end
    end
  end

  # Toggles the filter dropdown open/closed.
  def handle_event("toggle_filter_dropdown", _params, socket) do
    {:noreply, assign(socket, :filter_dropdown_open, !socket.assigns.filter_dropdown_open)}
  end

  # Closes the filter dropdown (used by phx-click-away).
  def handle_event("close_filter_dropdown", _params, socket) do
    {:noreply, assign(socket, :filter_dropdown_open, false)}
  end

  # Sets the main timeline filter (all, following, local, federated).
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    if filter == socket.assigns.current_filter do
      {:noreply, socket}
    else
      current_view = socket.assigns.timeline_filter || "all"
      {:noreply, push_patch(socket, to: ~p"/timeline?filter=#{filter}&view=#{current_view}")}
    end
  end

  # Sets the software filter (all, mastodon, pixelfed, lemmy, etc).
  def handle_event("set_software_filter", %{"software" => software}, socket) do
    if software == socket.assigns.software_filter do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:software_filter, software)
       |> Helpers.apply_timeline_filter()}
    end
  end

  # ==================== Draft Operations ====================

  # Saves the current post as a draft.
  def handle_event("save_draft", _params, socket) do
    user = socket.assigns.current_user

    if !user do
      {:noreply, put_flash(socket, :error, "You must be logged in to save drafts")}
    else
      content = socket.assigns.new_post_content
      title = socket.assigns.new_post_title
      visibility = socket.assigns.new_post_visibility
      media_urls = socket.assigns.pending_media_urls
      alt_texts = socket.assigns.pending_media_alt_texts || %{}
      content_warning = socket.assigns.new_post_content_warning
      draft_id = socket.assigns[:editing_draft_id]

      opts = [
        content: content,
        title: title,
        visibility: visibility,
        media_urls: media_urls,
        alt_texts: alt_texts,
        content_warning: content_warning
      ]

      opts = if draft_id, do: Keyword.put(opts, :draft_id, draft_id), else: opts

      case Drafts.save_draft(user.id, opts) do
        {:ok, draft} ->
          {:noreply,
           socket
           |> assign(:new_post_content, "")
           |> assign(:new_post_title, nil)
           |> assign(:new_post_content_warning, nil)
           |> assign(:new_post_sensitive, false)
           |> assign(:show_cw_input, false)
           |> assign(:show_post_composer, false)
           |> assign(:pending_media_urls, [])
           |> assign(:pending_media_alt_texts, %{})
           |> assign(:editing_draft_id, nil)
           |> update(:user_drafts, fn drafts -> [draft | drafts || []] end)
           |> put_flash(:info, "Draft saved")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to save draft")}
      end
    end
  end

  # Loads a draft into the composer for editing.
  def handle_event("edit_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = String.to_integer(draft_id)

    case Drafts.get_draft(draft_id, user.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Draft not found")}

      draft ->
        {:noreply,
         socket
         |> assign(:show_post_composer, true)
         |> assign(:new_post_content, draft.content || "")
         |> assign(:new_post_title, draft.title)
         |> assign(:new_post_visibility, draft.visibility || "followers")
         |> assign(:new_post_content_warning, draft.content_warning)
         |> assign(:new_post_sensitive, draft.content_warning && draft.content_warning != "")
         |> assign(:show_cw_input, draft.content_warning && draft.content_warning != "")
         |> assign(:pending_media_urls, draft.media_urls || [])
         |> assign(:pending_media_alt_texts, (draft.media_metadata || %{})["alt_texts"] || %{})
         |> assign(:editing_draft_id, draft.id)}
    end
  end

  # Publishes a draft as a regular post.
  def handle_event("publish_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = String.to_integer(draft_id)

    case Drafts.publish_draft(draft_id, user.id) do
      {:ok, published_post} ->
        # Record stats
        Task.start(fn ->
          Elektrine.Accounts.TrustLevel.increment_stat(user.id, :posts_created)
          Elektrine.Accounts.TrustLevel.increment_stat(user.id, :topics_created)
        end)

        {:noreply,
         socket
         |> update(:user_drafts, fn drafts ->
           Enum.reject(drafts || [], &(&1.id == draft_id))
         end)
         |> update(:timeline_posts, fn posts -> [published_post | posts] end)
         |> Helpers.apply_timeline_filter()
         |> put_flash(:info, "Draft published!")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Draft not found")}

      {:error, :empty_draft} ->
        {:noreply, put_flash(socket, :error, "Cannot publish an empty draft")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to publish draft")}
    end
  end

  # Deletes a draft.
  def handle_event("delete_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = String.to_integer(draft_id)

    case Drafts.delete_draft(draft_id, user.id) do
      {:ok, _deleted_draft} ->
        {:noreply,
         socket
         |> update(:user_drafts, fn drafts ->
           Enum.reject(drafts || [], &(&1.id == draft_id))
         end)
         |> put_flash(:info, "Draft deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Draft not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete draft")}
    end
  end

  # Shows the drafts panel/dropdown.
  def handle_event("show_drafts", _params, socket) do
    user = socket.assigns.current_user

    if user do
      drafts = Drafts.list_drafts(user.id, limit: 20)
      {:noreply, assign(socket, user_drafts: drafts, show_drafts_panel: true)}
    else
      {:noreply, socket}
    end
  end

  # Hides the drafts panel.
  def handle_event("hide_drafts", _params, socket) do
    {:noreply, assign(socket, :show_drafts_panel, false)}
  end

  # Executes the actual load-more fetch.
  def handle_load_more(socket) do
    case allow_timeline_read(socket, :load_more) do
      :ok ->
        do_handle_load_more(socket)

      {:error, retry_after} ->
        socket
        |> assign(:loading_more, false)
        |> put_flash(
          :error,
          "You're switching timeline pages too quickly. Please retry in #{retry_after}s."
        )
    end
  end

  defp do_handle_load_more(socket) do
    current_posts = socket.assigns.timeline_posts
    before_id = if Enum.empty?(current_posts), do: nil, else: List.last(current_posts).id
    current_user = socket.assigns[:current_user]
    timeline_view = socket.assigns.timeline_filter || "all"

    more_posts =
      case timeline_view do
        "replies" ->
          Social.get_federated_replies(
            limit: 20,
            before_id: before_id,
            user_id: current_user && current_user.id
          )

        "friends" ->
          if current_user do
            Social.get_friends_timeline(current_user.id, limit: 20, before_id: before_id)
          else
            []
          end

        "my_posts" ->
          if current_user do
            Social.get_user_timeline_posts(current_user.id,
              limit: 20,
              before_id: before_id,
              viewer_id: current_user.id
            )
          else
            []
          end

        "trusted" ->
          Social.get_trusted_timeline(
            limit: 20,
            before_id: before_id,
            user_id: current_user && current_user.id
          )

        _ ->
          case socket.assigns.current_filter do
            "all" ->
              if current_user do
                Social.get_public_timeline(
                  limit: 20,
                  before_id: before_id,
                  user_id: current_user.id
                )
              else
                Social.get_public_timeline(limit: 20, before_id: before_id)
              end

            "following" ->
              if current_user do
                Social.get_combined_feed(current_user.id,
                  limit: 20,
                  before_id: before_id
                )
              else
                Social.get_public_timeline(limit: 20, before_id: before_id)
              end

            "local" ->
              if current_user do
                Social.get_local_timeline(
                  limit: 20,
                  before_id: before_id,
                  user_id: current_user.id
                )
              else
                Social.get_local_timeline(limit: 20, before_id: before_id)
              end

            "federated" ->
              Social.get_public_federated_posts(limit: 20, before_id: before_id)

            _ ->
              []
          end
      end

    merged_lemmy_counts = socket.assigns.lemmy_counts || %{}

    # Load replies for new posts and include in follows check
    new_post_ids = Enum.map(more_posts, & &1.id)

    new_post_replies =
      if socket.assigns[:current_user] do
        Elektrine.Social.get_direct_replies_for_posts(new_post_ids,
          user_id: socket.assigns.current_user.id,
          limit_per_post: 3
        )
      else
        Elektrine.Social.get_direct_replies_for_posts(new_post_ids, limit_per_post: 3)
      end

    all_new_messages = more_posts ++ List.flatten(Map.values(new_post_replies))

    merged_user_follows =
      if socket.assigns[:current_user] && !Enum.empty?(more_posts) do
        new_follows = Helpers.get_user_follows(socket.assigns.current_user.id, all_new_messages)
        Map.merge(socket.assigns.user_follows, new_follows)
      else
        socket.assigns.user_follows
      end

    merged_pending_follows =
      if socket.assigns[:current_user] && !Enum.empty?(more_posts) do
        new_pending =
          Helpers.get_pending_follows(socket.assigns.current_user.id, all_new_messages)

        Map.merge(socket.assigns.pending_follows || %{}, new_pending)
      else
        socket.assigns.pending_follows || %{}
      end

    merged_post_replies = Map.merge(socket.assigns.post_replies || %{}, new_post_replies)

    # Track if we've reached the end (no more posts to load)
    no_more_posts = Enum.empty?(more_posts)
    updated_timeline_posts = current_posts ++ more_posts

    updated_base_timeline_posts =
      if special_timeline_view?(timeline_view) do
        Map.get(socket.assigns, :base_timeline_posts, [])
      else
        updated_timeline_posts
      end

    updated_special_view_cache =
      if special_timeline_view?(timeline_view) do
        cache_key = {socket.assigns.current_filter, timeline_view}
        special_view_cache = Map.get(socket.assigns, :special_view_cache, %{})

        existing_cache =
          Map.get(special_view_cache, cache_key, %{
            posts: current_posts,
            post_replies: socket.assigns.post_replies || %{}
          })

        cached_posts =
          (Map.get(existing_cache, :posts, current_posts) ++ more_posts)
          |> Enum.uniq_by(& &1.id)

        cached_replies = Map.merge(Map.get(existing_cache, :post_replies, %{}), new_post_replies)

        Map.put(special_view_cache, cache_key, %{
          posts: cached_posts,
          post_replies: cached_replies
        })
      else
        Map.get(socket.assigns, :special_view_cache, %{})
      end

    socket
    |> assign(:loading_more, false)
    |> assign(:no_more_posts, no_more_posts)
    |> assign(:lemmy_counts, merged_lemmy_counts)
    |> assign(:base_timeline_posts, updated_base_timeline_posts)
    |> assign(:special_view_cache, updated_special_view_cache)
    |> assign(:user_follows, merged_user_follows)
    |> assign(:pending_follows, merged_pending_follows)
    |> assign(:post_replies, merged_post_replies)
    |> assign(:timeline_posts, updated_timeline_posts)
    |> Helpers.apply_timeline_filter()
    |> maybe_queue_remote_data_fetch(more_posts)
    |> maybe_schedule_background_refresh_jobs(more_posts)
    |> maybe_schedule_reply_ingestion_jobs(more_posts)
  end

  defp special_timeline_view?(view), do: view in ["replies", "friends", "my_posts", "trusted"]

  defp timeline_remote_enrichment_enabled? do
    Application.get_env(:elektrine, :timeline_remote_enrichment, false)
  end

  defp maybe_queue_remote_data_fetch(socket, posts) do
    if timeline_remote_enrichment_enabled?() && posts != [] do
      send(self(), {:load_remote_data, posts})
    end

    socket
  end

  defp maybe_schedule_background_refresh_jobs(socket, posts) do
    message_ids =
      posts
      |> Enum.filter(&(&1.federated == true && is_integer(&1.id)))
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.take(20)

    if message_ids != [] do
      Task.start(fn ->
        Enum.each(message_ids, fn message_id ->
          _ = Elektrine.ActivityPub.RefreshCountsWorker.schedule_single_refresh(message_id)
        end)
      end)
    end

    socket
  end

  defp maybe_schedule_reply_ingestion_jobs(socket, posts) do
    message_ids =
      posts
      |> Enum.filter(&(&1.federated == true && is_integer(&1.id) && (&1.reply_count || 0) > 0))
      |> Enum.reject(fn post ->
        Map.get(socket.assigns.post_replies || %{}, post.id, []) != []
      end)
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.take(20)

    if message_ids != [] do
      Task.start(fn ->
        Enum.each(message_ids, fn message_id ->
          _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(message_id)
        end)
      end)
    end

    socket
  end

  defp allow_timeline_read(socket, action) do
    TimelineRateLimiter.allow_read(timeline_rate_limit_identifier(socket, action))
  end

  defp timeline_rate_limit_identifier(socket, action) do
    actor =
      case socket.assigns[:current_user] do
        %{id: user_id} -> "user:#{user_id}"
        _ -> "anon:#{socket.id || "unknown"}"
      end

    "liveview:#{action}:#{actor}"
  end

  defp maybe_restore_base_timeline(socket, previous_view) do
    if special_timeline_view?(previous_view) do
      base_posts = Map.get(socket.assigns, :base_timeline_posts, [])

      if Enum.empty?(base_posts) do
        socket
      else
        assign(socket, :timeline_posts, base_posts)
      end
    else
      socket
    end
  end
end
