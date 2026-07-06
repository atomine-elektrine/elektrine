defmodule ElektrineSocialWeb.TimelineLive.Operations.PostOperations do
  @moduledoc "Handles post-related operations for the timeline LiveView.\nIncludes post creation, deletion, filtering, and composer interactions.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: ElektrineWeb.Endpoint, router: ElektrineWeb.Router
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Recommendations
  alias Elektrine.Timeline.RateLimiter, as: TimelineRateLimiter
  alias Elektrine.Utils.SafeConvert
  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers
  alias ElektrineSocialWeb.TimelineLive.ReplyContextPreviews
  alias ElektrineWeb.AdminSecurity

  @load_more_page_size 20
  @load_more_max_batches 8

  @starter_pack_drafts [
    {"Introduce yourself",
     "A quick intro post: who you are, what you're into, and what kind of people you'd like to meet here."},
    {"Share what you're building",
     "Post a work-in-progress, side project, sketch, or idea you're exploring this week."},
    {"Ask for recommendations",
     "Ask the timeline for books, tools, communities, or feeds worth following in your interests."}
  ]

  def handle_event("toggle_post_composer", _params, socket) do
    show_post_composer = !socket.assigns.show_post_composer
    current_user = socket.assigns[:current_user]

    {:noreply,
     socket
     |> assign(:show_post_composer, show_post_composer)
     |> assign(
       :composer_intent,
       if(show_post_composer, do: "post", else: socket.assigns.composer_intent)
     )
     |> assign(:new_post_title, nil)
     |> assign(:new_post_content, "")
     |> assign(:new_post_content_warning, nil)
     |> assign(:new_post_sensitive, false)
     |> assign(:new_post_scheduled_at, "")
     |> assign(:show_cw_input, false)
     |> assign(
       :new_post_visibility,
       if(show_post_composer,
         do: (current_user && current_user.default_post_visibility) || "public",
         else: socket.assigns.new_post_visibility
       )
     )
     |> assign(:editing_draft_id, nil)
     |> assign(:draft_auto_saved, false)
     |> assign(:draft_saving, false)}
  end

  def handle_event("update_post_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, :new_post_title, title)}
  end

  def handle_event("update_visibility", %{"visibility" => visibility}, socket) do
    {:noreply, assign(socket, :new_post_visibility, visibility)}
  end

  def handle_event("update_scheduled_at", %{"scheduled_at" => scheduled_at}, socket) do
    {:noreply, assign(socket, :new_post_scheduled_at, scheduled_at || "")}
  end

  def handle_event("toggle_content_warning", _params, socket) do
    {:noreply,
     socket
     |> update(:show_cw_input, &(!&1))
     |> assign(
       :new_post_content_warning,
       if socket.assigns.show_cw_input do
         nil
       else
         socket.assigns.new_post_content_warning
       end
     )}
  end

  def handle_event("update_content_warning", %{"cw" => cw}, socket) do
    {:noreply,
     socket
     |> assign(:new_post_content_warning, cw)
     |> assign(:new_post_sensitive, Elektrine.Strings.present?(cw))}
  end

  def handle_event("update_post_content", %{"content" => content}, socket) do
    urls = Elektrine.Social.LinkPreviewFetcher.extract_urls(content)
    current_title = socket.assigns.new_post_title
    should_fetch_title = not Elektrine.Strings.present?(current_title) && urls != []

    updated_socket =
      if should_fetch_title do
        metadata = Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(hd(urls))

        if Elektrine.Strings.present?(metadata[:title]) do
          assign(socket, :new_post_title, metadata[:title])
        else
          socket
        end
      else
        socket
      end

    {:noreply, assign(updated_socket, :new_post_content, content)}
  end

  # Lightweight live updates used by the timeline composer to keep counters responsive
  # without triggering draft persistence on every keystroke.
  def handle_event("update_post_content_live", %{"value" => content}, socket) do
    {:noreply, assign(socket, :new_post_content, content)}
  end

  def handle_event("autosave_draft", params, socket) do
    user = socket.assigns.current_user

    if user do
      content = params["content"] || socket.assigns.new_post_content || ""
      title = params["title"] || socket.assigns.new_post_title
      cw = params["cw"]
      scheduled_at_input = params["scheduled_at"] || socket.assigns[:new_post_scheduled_at] || ""

      has_content =
        Elektrine.Strings.present?(content) || not is_nil(title) ||
          !Enum.empty?(socket.assigns.pending_media_urls)

      if has_content do
        socket =
          socket
          |> assign(:new_post_content, content)
          |> assign(:new_post_title, Elektrine.Strings.present(title))
          |> assign(:new_post_content_warning, cw)
          |> assign(:new_post_sensitive, Elektrine.Strings.present?(cw))
          |> assign(:new_post_scheduled_at, scheduled_at_input)
          |> assign(:draft_saving, true)

        urls = Elektrine.Social.LinkPreviewFetcher.extract_urls(content)
        current_title = socket.assigns.new_post_title

        socket =
          if not Elektrine.Strings.present?(current_title) && urls != [] do
            metadata = Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(hd(urls))

            if Elektrine.Strings.present?(metadata[:title]) do
              assign(socket, :new_post_title, metadata[:title])
            else
              socket
            end
          else
            socket
          end

        visibility = socket.assigns.new_post_visibility
        media_urls = socket.assigns.pending_media_urls
        media_metadata = pending_media_metadata(socket)
        alt_texts = socket.assigns.pending_media_alt_texts || %{}
        draft_id = socket.assigns[:editing_draft_id]

        opts = [
          content: content,
          title: socket.assigns.new_post_title,
          visibility: visibility,
          media_urls: media_urls,
          media_metadata: media_metadata,
          alt_texts: alt_texts,
          content_warning: socket.assigns.new_post_content_warning,
          sensitive: socket.assigns.new_post_sensitive,
          scheduled_at: parse_schedule_input_for_autosave(scheduled_at_input)
        ]

        opts =
          if draft_id do
            Keyword.put(opts, :draft_id, draft_id)
          else
            opts
          end

        case Drafts.save_draft(user.id, opts) do
          {:ok, draft} ->
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
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_queued_posts", _params, socket) do
    queued =
      Helpers.filter_posts_by_feed_display_toggles(
        socket.assigns.queued_posts,
        socket.assigns[:hide_boosts],
        socket.assigns[:hide_replies]
      )

    if Enum.empty?(queued) do
      {:noreply, assign(socket, :queued_posts, [])}
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

  def handle_event(
        "create_post",
        %{"content" => content, "visibility" => visibility} = params,
        socket
      ) do
    user = socket.assigns.current_user
    has_content = Elektrine.Strings.present?(content)
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
      media_metadata = pending_media_metadata(socket)
      alt_texts = socket.assigns.pending_media_alt_texts || %{}
      scheduled_at_input = params["scheduled_at"] || socket.assigns[:new_post_scheduled_at] || ""
      post_opts = [visibility: visibility, media_urls: uploaded_files]

      post_opts =
        if map_size(media_metadata) == 0 do
          post_opts
        else
          Keyword.put(post_opts, :media_metadata, media_metadata)
        end

      post_opts =
        if title do
          Keyword.put(post_opts, :title, title)
        else
          post_opts
        end

      post_opts =
        if Enum.empty?(alt_texts) do
          post_opts
        else
          Keyword.put(post_opts, :alt_texts, alt_texts)
        end

      post_opts =
        if socket.assigns.new_post_content_warning do
          Keyword.put(post_opts, :content_warning, socket.assigns.new_post_content_warning)
        else
          post_opts
        end

      post_opts =
        if socket.assigns.new_post_sensitive do
          Keyword.put(post_opts, :sensitive, true)
        else
          post_opts
        end

      case parse_schedule_input(scheduled_at_input) do
        {:ok, scheduled_at} ->
          if scheduled_at do
            schedule_post(socket, user, content, post_opts, scheduled_at)
          else
            publish_post_now(socket, user, content, post_opts)
          end

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    end
  end

  def handle_event("delete_post", %{"message_id" => message_id}, socket) do
    message_id = event_id(message_id)
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

  def handle_event("delete_post_admin", %{"message_id" => message_id}, socket) do
    case AdminSecurity.validate_live_admin_action(socket.assigns) do
      :ok ->
        message_id = event_id(message_id)

        if message_id == 0 do
          {:noreply, put_flash(socket, :error, "Failed to delete post")}
        else
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
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AdminSecurity.error_message(reason))}
    end
  end

  def handle_event("view_post", %{"message_id" => message_id}, socket) do
    {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(message_id))}
  end

  def handle_event("copy_post_link", %{"message_id" => message_id}, socket) do
    message_id = event_id(message_id)
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

  def handle_event("mute_thread", %{"message_id" => message_id}, socket) do
    handle_thread_mute(socket, message_id, :mute)
  end

  def handle_event("unmute_thread", %{"message_id" => message_id}, socket) do
    handle_thread_mute(socket, message_id, :unmute)
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

  def handle_event("report_post", %{"message_id" => message_id}, socket) do
    message_id = event_id(message_id)
    post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

    if post do
      report_metadata = %{
        "sender_id" => post.sender_id,
        "content_preview" => ElektrineWeb.HtmlHelpers.plain_text_preview(post.content, 100),
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

  def handle_event("load_more_posts", _params, socket) do
    if socket.assigns.loading_more || socket.assigns[:no_more_posts] do
      {:noreply, socket}
    else
      send(self(), :load_more_timeline_posts)
      {:noreply, assign(socket, :loading_more, true)}
    end
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.loading_more || socket.assigns[:no_more_posts] do
      {:noreply, socket}
    else
      handle_event("load_more_posts", %{}, socket)
    end
  end

  def handle_event("filter_timeline", %{"filter" => filter}, socket) do
    current_view = socket.assigns.timeline_filter || "all"

    if filter == current_view do
      {:noreply, assign(socket, :filter_dropdown_open, false)}
    else
      path = timeline_path(socket, socket.assigns.current_filter, filter)

      cond do
        special_timeline_view?(filter) ->
          {:noreply,
           socket
           |> assign(:filter_dropdown_open, false)
           |> assign(:queued_posts, [])
           |> Helpers.queue_timeline_reload(socket.assigns.current_filter, filter)
           |> push_patch(to: path)}

        special_timeline_view?(current_view) &&
            Enum.empty?(Map.get(socket.assigns, :base_timeline_posts, [])) ->
          {:noreply, socket |> assign(:filter_dropdown_open, false) |> push_patch(to: path)}

        true ->
          updated_socket =
            socket
            |> assign(:filter_dropdown_open, false)
            |> assign(:timeline_filter, filter)
            |> assign(:queued_posts, [])
            |> assign(:loading_timeline, false)
            |> maybe_restore_base_timeline(current_view)
            |> Helpers.apply_timeline_filter()

          {:noreply, push_patch(updated_socket, to: path)}
      end
    end
  end

  def handle_event("toggle_filter_dropdown", _params, socket) do
    {:noreply, assign(socket, :filter_dropdown_open, !socket.assigns.filter_dropdown_open)}
  end

  def handle_event("close_filter_dropdown", _params, socket) do
    {:noreply, assign(socket, :filter_dropdown_open, false)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    if filter == socket.assigns.current_filter do
      {:noreply, socket}
    else
      current_view = socket.assigns.timeline_filter || "all"
      {:noreply, push_patch(socket, to: timeline_path(socket, filter, current_view))}
    end
  end

  def handle_event("set_software_filter", %{"software" => software}, socket) do
    if software == socket.assigns.software_filter do
      {:noreply, socket}
    else
      queued_posts = socket.assigns.queued_posts |> Helpers.filter_posts_by_software(software)

      {:noreply,
       socket
       |> assign(:software_filter, software)
       |> assign(:queued_posts, queued_posts)
       |> Helpers.apply_timeline_filter()}
    end
  end

  def handle_event("toggle_hide_boosts", _params, socket) do
    {:noreply,
     socket
     |> update(:hide_boosts, &(!&1))
     |> prune_queued_posts_for_display_toggles()
     |> Helpers.apply_timeline_filter(true)}
  end

  def handle_event("toggle_hide_replies", _params, socket) do
    {:noreply,
     socket
     |> update(:hide_replies, &(!&1))
     |> prune_queued_posts_for_display_toggles()
     |> Helpers.apply_timeline_filter(true)}
  end

  def handle_event("save_draft", _params, socket) do
    user = socket.assigns.current_user

    if user do
      content = socket.assigns.new_post_content
      title = socket.assigns.new_post_title
      visibility = socket.assigns.new_post_visibility
      media_urls = socket.assigns.pending_media_urls
      media_metadata = pending_media_metadata(socket)
      alt_texts = socket.assigns.pending_media_alt_texts || %{}
      content_warning = socket.assigns.new_post_content_warning
      draft_id = socket.assigns[:editing_draft_id]
      scheduled_at_input = socket.assigns[:new_post_scheduled_at] || ""

      opts = [
        content: content,
        title: title,
        visibility: visibility,
        media_urls: media_urls,
        media_metadata: media_metadata,
        alt_texts: alt_texts,
        content_warning: content_warning,
        sensitive: socket.assigns.new_post_sensitive
      ]

      opts =
        if draft_id do
          Keyword.put(opts, :draft_id, draft_id)
        else
          opts
        end

      case parse_schedule_input(scheduled_at_input) do
        {:ok, scheduled_at} ->
          opts = Keyword.put(opts, :scheduled_at, scheduled_at)

          case Drafts.save_draft(user.id, opts) do
            {:ok, draft} ->
              {:noreply,
               socket
               |> assign(:new_post_content, "")
               |> assign(:new_post_title, nil)
               |> assign(:new_post_content_warning, nil)
               |> assign(:new_post_sensitive, false)
               |> assign(:new_post_scheduled_at, "")
               |> assign(:show_cw_input, false)
               |> assign(:show_post_composer, false)
               |> assign(:pending_media_urls, [])
               |> assign(:pending_media_attachments, [])
               |> assign(:pending_media_alt_texts, %{})
               |> assign(:editing_draft_id, nil)
               |> update(:user_drafts, fn drafts ->
                 drafts = drafts || []
                 [draft | Enum.reject(drafts, &(&1.id == draft.id))]
               end)
               |> put_flash(
                 :info,
                 if(scheduled_at, do: "Scheduled draft saved", else: "Draft saved")
               )}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Failed to save draft")}
          end

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be logged in to save drafts")}
    end
  end

  def handle_event("edit_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = event_id(draft_id)

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
         |> assign(
           :new_post_sensitive,
           draft.sensitive || Elektrine.Strings.present?(draft.content_warning)
         )
         |> assign(:new_post_scheduled_at, format_schedule_input(draft.scheduled_at))
         |> assign(:show_cw_input, Elektrine.Strings.present?(draft.content_warning))
         |> assign(:pending_media_urls, draft.media_urls || [])
         |> assign(:pending_media_attachments, draft_attachment_metadata(draft))
         |> assign(:pending_media_alt_texts, draft_alt_texts(draft))
         |> assign(:editing_draft_id, draft.id)}
    end
  end

  def handle_event("publish_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = event_id(draft_id)

    case Drafts.publish_draft(draft_id, user.id) do
      {:ok, published_post} ->
        Elektrine.Accounts.TrustLevel.increment_stat(user.id, :posts_created)
        Elektrine.Accounts.TrustLevel.increment_stat(user.id, :topics_created)

        {:noreply,
         socket
         |> update(:user_drafts, fn drafts -> Enum.reject(drafts || [], &(&1.id == draft_id)) end)
         |> update(:timeline_posts, fn posts -> [published_post | posts] end)
         |> Helpers.apply_timeline_filter()
         |> put_flash(:info, "Draft published!")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Draft not found")}

      {:error, :empty_draft} ->
        {:noreply, put_flash(socket, :error, "Cannot publish an empty draft")}

      {:error, :scheduled_for_future} ->
        {:noreply,
         put_flash(socket, :error, "Scheduled posts stay queued until their scheduled time")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to publish draft")}
    end
  end

  def handle_event("delete_draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    draft_id = event_id(draft_id)

    case Drafts.delete_draft(draft_id, user.id) do
      {:ok, _deleted_draft} ->
        {:noreply,
         socket
         |> update(:user_drafts, fn drafts -> Enum.reject(drafts || [], &(&1.id == draft_id)) end)
         |> put_flash(:info, "Draft deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Draft not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete draft")}
    end
  end

  def handle_event("show_drafts", _params, socket) do
    user = socket.assigns.current_user

    if user do
      drafts = Drafts.list_drafts(user.id, limit: 20)
      {:noreply, assign(socket, user_drafts: drafts, show_drafts_panel: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("hide_drafts", _params, socket) do
    {:noreply, assign(socket, :show_drafts_panel, false)}
  end

  def handle_event("seed_starter_pack", _params, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "You must be signed in to seed a starter pack")}

      user.onboarding_completed ->
        {:noreply, put_flash(socket, :info, "Starter packs are reserved for newer accounts")}

      true ->
        existing_titles =
          socket.assigns.user_drafts
          |> Kernel.||([])
          |> MapSet.new(&(&1.title || ""))

        new_drafts =
          @starter_pack_drafts
          |> Enum.reject(fn {title, _content} -> MapSet.member?(existing_titles, title) end)
          |> Enum.map(fn {title, content} ->
            Drafts.create_draft(user.id,
              title: title,
              content: content,
              visibility: user.default_post_visibility || "public"
            )
          end)
          |> Enum.flat_map(fn
            {:ok, draft} -> [draft]
            _ -> []
          end)

        if new_drafts == [] do
          {:noreply,
           socket
           |> assign(:show_drafts_panel, true)
           |> put_flash(:info, "Your starter pack is already waiting in drafts")}
        else
          {:noreply,
           socket
           |> assign(:user_drafts, new_drafts ++ (socket.assigns.user_drafts || []))
           |> assign(:show_drafts_panel, true)
           |> put_flash(:info, "Starter pack added to your drafts")}
        end
    end
  end

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

  defp publish_post_now(socket, user, content, post_opts) do
    case Social.create_timeline_post(user.id, content, post_opts) do
      {:ok, real_post} ->
        if socket.assigns[:editing_draft_id] do
          Drafts.delete_draft(socket.assigns.editing_draft_id, user.id)
        end

        Elektrine.Accounts.TrustLevel.increment_stat(user.id, :posts_created)
        Elektrine.Accounts.TrustLevel.increment_stat(user.id, :topics_created)

        {:noreply,
         socket
         |> assign(:new_post_content, "")
         |> assign(:new_post_title, nil)
         |> assign(:new_post_content_warning, nil)
         |> assign(:new_post_sensitive, false)
         |> assign(:new_post_scheduled_at, "")
         |> assign(:show_cw_input, false)
         |> assign(:show_post_composer, false)
         |> assign(:pending_media_urls, [])
         |> assign(:pending_media_attachments, [])
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

  defp schedule_post(socket, user, content, post_opts, scheduled_at) do
    draft_id = socket.assigns[:editing_draft_id]
    opts = Keyword.merge(post_opts, content: content, scheduled_at: scheduled_at)

    opts = if draft_id, do: Keyword.put(opts, :draft_id, draft_id), else: opts

    case Drafts.save_draft(user.id, opts) do
      {:ok, draft} ->
        updated_drafts =
          socket.assigns.user_drafts
          |> Kernel.||([])
          |> Enum.reject(&(&1.id == draft.id))
          |> then(&[draft | &1])

        {:noreply,
         socket
         |> assign(:new_post_content, "")
         |> assign(:new_post_title, nil)
         |> assign(:new_post_content_warning, nil)
         |> assign(:new_post_sensitive, false)
         |> assign(:new_post_scheduled_at, "")
         |> assign(:show_cw_input, false)
         |> assign(:show_post_composer, false)
         |> assign(:pending_media_urls, [])
         |> assign(:pending_media_attachments, [])
         |> assign(:pending_media_alt_texts, %{})
         |> assign(:editing_draft_id, nil)
         |> assign(:draft_auto_saved, false)
         |> assign(:draft_saving, false)
         |> assign(:user_drafts, updated_drafts)
         |> assign(:show_drafts_panel, true)
         |> put_flash(:info, "Post scheduled for #{format_scheduled_at(draft.scheduled_at)}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't schedule your post. Please try again.")}
    end
  end

  defp do_handle_load_more(socket) do
    current_posts = socket.assigns.timeline_posts
    search_query = socket.assigns[:search_query] || ""

    before_id =
      if Enum.empty?(current_posts) do
        nil
      else
        List.last(current_posts).id
      end

    timeline_view = socket.assigns.timeline_filter || "all"

    {more_posts, no_more_posts, saved_cursor} =
      load_more_until_visible(socket, current_posts, before_id)

    merged_lemmy_counts =
      Map.merge(
        socket.assigns.lemmy_counts || %{},
        Helpers.load_cached_lemmy_counts(more_posts, timeline_view)
      )

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
    updated_timeline_posts = Helpers.dedupe_posts(current_posts ++ more_posts)

    updated_gap_marker_ids =
      append_gap_marker(socket.assigns[:timeline_gap_marker_ids], current_posts, more_posts)

    updated_base_timeline_posts =
      if special_timeline_view?(timeline_view) do
        Map.get(socket.assigns, :base_timeline_posts, [])
      else
        updated_timeline_posts
      end

    updated_base_timeline_key =
      if special_timeline_view?(timeline_view) do
        Map.get(socket.assigns, :base_timeline_key)
      else
        {socket.assigns.current_filter, search_query}
      end

    updated_special_view_cache =
      if special_timeline_view?(timeline_view) do
        cache_key = {socket.assigns.current_filter, timeline_view, search_query}
        special_view_cache = Map.get(socket.assigns, :special_view_cache, %{})

        existing_cache =
          Map.get(special_view_cache, cache_key, %{
            posts: current_posts,
            post_replies: socket.assigns.post_replies || %{}
          })

        cached_posts =
          (Map.get(existing_cache, :posts, current_posts) ++ more_posts) |> Enum.uniq_by(& &1.id)

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
    |> assign(:base_timeline_key, updated_base_timeline_key)
    |> assign(:special_view_cache, updated_special_view_cache)
    |> assign(:user_follows, merged_user_follows)
    |> assign(:pending_follows, merged_pending_follows)
    |> assign(:post_replies, merged_post_replies)
    |> assign(:timeline_posts, updated_timeline_posts)
    |> assign(:timeline_gap_marker_ids, updated_gap_marker_ids)
    |> maybe_assign_saved_scroll_cursor(saved_cursor)
    |> maybe_merge_saved_item_folders(more_posts)
    |> Helpers.apply_timeline_filter()
    |> maybe_queue_reply_context_preview_fetch(more_posts)
    |> maybe_schedule_background_refresh_jobs(more_posts)
    |> maybe_schedule_reply_ingestion_jobs(more_posts)
  end

  defp load_more_until_visible(socket, current_posts, before_id) do
    previous_visible_ids = MapSet.new(socket.assigns[:filtered_post_ids] || [])

    saved_cursor =
      if saved_keyset_load_more?(socket), do: socket.assigns[:saved_scroll_cursor]

    do_load_more_until_visible(
      socket,
      current_posts,
      {before_id, saved_cursor},
      [],
      previous_visible_ids,
      @load_more_max_batches
    )
  end

  defp do_load_more_until_visible(
         _socket,
         _current_posts,
         {_before_id, saved_cursor},
         accumulated,
         _visible_ids,
         0
       ) do
    {accumulated, Enum.empty?(accumulated), saved_cursor}
  end

  defp do_load_more_until_visible(
         socket,
         current_posts,
         {before_id, saved_cursor},
         accumulated,
         previous_visible_ids,
         batches_left
       ) do
    {raw_page, next_saved_cursor} =
      fetch_more_posts(socket, before_id, saved_cursor, current_posts, accumulated)

    next_saved_cursor = next_saved_cursor || saved_cursor

    if raw_page == [] do
      {accumulated, true, next_saved_cursor}
    else
      page = reject_loaded_posts(raw_page, current_posts, accumulated)

      if page == [] do
        next_before_id = raw_page |> List.last() |> Map.get(:id)

        do_load_more_until_visible(
          socket,
          current_posts,
          {next_before_id, next_saved_cursor},
          accumulated,
          previous_visible_ids,
          batches_left - 1
        )
      else
        accumulated = Helpers.dedupe_posts(accumulated ++ page)
        candidate_posts = Helpers.dedupe_posts(current_posts ++ accumulated)

        candidate_visible_ids =
          socket
          |> Helpers.filter_timeline_posts(candidate_posts)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        if MapSet.difference(candidate_visible_ids, previous_visible_ids) |> MapSet.size() > 0 do
          {accumulated, false, next_saved_cursor}
        else
          next_before_id = raw_page |> List.last() |> Map.get(:id)

          do_load_more_until_visible(
            socket,
            current_posts,
            {next_before_id, next_saved_cursor},
            accumulated,
            previous_visible_ids,
            batches_left - 1
          )
        end
      end
    end
  end

  defp reject_loaded_posts(posts, current_posts, accumulated_posts) do
    loaded_ids =
      (current_posts ++ accumulated_posts)
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(posts, fn post -> MapSet.member?(loaded_ids, Map.get(post, :id)) end)
  end

  # Keyset pagination applies to the saved source filter whenever load-more is
  # served by fetch_more_posts_for_source_filter (i.e. not a special view).
  defp saved_keyset_load_more?(socket) do
    socket.assigns.current_filter == "saved" &&
      !special_timeline_view?(socket.assigns.timeline_filter || "all")
  end

  # Only the saved keyset path yields a cursor; keep the existing assign
  # (reset by Helpers.queue_timeline_reload) for every other load path.
  defp maybe_assign_saved_scroll_cursor(socket, nil), do: socket

  defp maybe_assign_saved_scroll_cursor(socket, saved_cursor) do
    assign(socket, :saved_scroll_cursor, saved_cursor)
  end

  # Appended saved posts need folder membership entries so the folder badge
  # and move-to-folder menu render correctly (mirrors assign_saved_item_folders
  # on the initial load).
  defp maybe_merge_saved_item_folders(socket, more_posts) do
    user = socket.assigns[:current_user]

    if user && socket.assigns.current_filter == "saved" && more_posts != [] do
      message_ids =
        more_posts
        |> Enum.map(& &1.id)
        |> Enum.filter(&is_integer/1)

      assign(
        socket,
        :saved_item_folders,
        Map.merge(
          socket.assigns[:saved_item_folders] || %{},
          Social.saved_item_folder_map(user.id, message_ids)
        )
      )
    else
      socket
    end
  end

  # Returns {page, next_saved_cursor}. next_saved_cursor is non-nil only for
  # the saved keyset load-more path; every other path pages by before_id.
  defp fetch_more_posts(socket, before_id, saved_cursor, current_posts, accumulated_posts) do
    current_user = socket.assigns[:current_user]
    timeline_view = socket.assigns.timeline_filter || "all"
    search_query = socket.assigns[:search_query] || ""
    session_context = socket.assigns[:session_context] || %{}
    source_filter = socket.assigns.current_filter || "all"
    loaded_posts = Helpers.dedupe_posts(current_posts ++ accumulated_posts)

    case timeline_view do
      "replies" ->
        {Social.get_federated_replies(
           limit: @load_more_page_size,
           before_id: before_id,
           user_id: current_user && current_user.id,
           search_query: search_query,
           source_filter: source_filter
         ), nil}

      "friends" ->
        if current_user do
          {Social.get_friends_timeline(current_user.id,
             limit: @load_more_page_size,
             before_id: before_id,
             search_query: search_query
           ), nil}
        else
          {[], nil}
        end

      "my_posts" ->
        if current_user do
          {Social.get_user_timeline_posts(current_user.id,
             limit: @load_more_page_size,
             before_id: before_id,
             viewer_id: current_user.id,
             search_query: search_query
           ), nil}
        else
          {[], nil}
        end

      "trusted" ->
        {Social.get_trusted_timeline(
           limit: @load_more_page_size,
           before_id: before_id,
           user_id: current_user && current_user.id,
           search_query: search_query
         ), nil}

      "communities" ->
        if current_user do
          {Social.get_public_community_posts(
             limit: @load_more_page_size,
             before_id: before_id,
             user_id: current_user.id,
             search_query: search_query,
             source_filter: source_filter
           ), nil}
        else
          {Social.get_public_community_posts(
             limit: @load_more_page_size,
             before_id: before_id,
             search_query: search_query,
             source_filter: source_filter
           ), nil}
        end

      _ ->
        fetch_more_posts_for_source_filter(
          source_filter,
          current_user,
          before_id,
          search_query,
          session_context,
          loaded_posts,
          saved_cursor: saved_cursor,
          bookmark_folder_id: socket.assigns[:selected_bookmark_folder_id]
        )
    end
  end

  # Each clause returns {page, next_saved_cursor}; only the "saved" clause
  # paginates by keyset cursor (saved order), so it is the only one that
  # produces a non-nil cursor.
  defp fetch_more_posts_for_source_filter(
         "saved",
         current_user,
         _before_id,
         search_query,
         _session_context,
         _loaded_posts,
         paging
       ) do
    if current_user do
      Social.get_saved_posts_with_cursor(current_user.id,
        limit: @load_more_page_size,
        cursor: Keyword.get(paging, :saved_cursor),
        search_query: search_query,
        bookmark_folder_id: Keyword.get(paging, :bookmark_folder_id)
      )
    else
      {[], nil}
    end
  end

  defp fetch_more_posts_for_source_filter(
         "home",
         current_user,
         before_id,
         search_query,
         _session_context,
         _loaded_posts,
         _paging
       ) do
    if current_user do
      {Social.get_combined_feed(current_user.id,
         limit: @load_more_page_size,
         before_id: before_id,
         search_query: search_query
       ), nil}
    else
      {Social.get_public_timeline(
         limit: @load_more_page_size,
         before_id: before_id,
         search_query: search_query
       ), nil}
    end
  end

  defp fetch_more_posts_for_source_filter(
         "for_you",
         current_user,
         before_id,
         search_query,
         session_context,
         loaded_posts,
         _paging
       ) do
    if current_user do
      current_ids = MapSet.new(Enum.map(loaded_posts, & &1.id))

      posts =
        Recommendations.get_for_you_feed(current_user.id,
          limit: length(loaded_posts) + @load_more_page_size,
          session_context: session_context
        )
        |> Helpers.filter_posts_by_search_query(search_query)
        |> Enum.reject(fn post -> MapSet.member?(current_ids, post.id) end)
        |> Enum.take(@load_more_page_size)

      {posts, nil}
    else
      {Social.get_public_timeline(
         limit: @load_more_page_size,
         before_id: before_id,
         search_query: search_query
       ), nil}
    end
  end

  defp fetch_more_posts_for_source_filter(
         filter,
         current_user,
         before_id,
         search_query,
         _session_context,
         _loaded_posts,
         _paging
       ) do
    posts =
      case filter do
        "all" ->
          get_public_timeline_page(current_user, before_id, search_query)

        "following" ->
          if current_user do
            Social.get_combined_feed(current_user.id,
              limit: @load_more_page_size,
              before_id: before_id,
              search_query: search_query
            )
          else
            Social.get_public_timeline(
              limit: @load_more_page_size,
              before_id: before_id,
              search_query: search_query
            )
          end

        "explore" ->
          get_public_timeline_page(current_user, before_id, search_query)

        "local" ->
          if current_user do
            Social.get_local_timeline(
              limit: @load_more_page_size,
              before_id: before_id,
              user_id: current_user.id,
              search_query: search_query
            )
          else
            Social.get_local_timeline(
              limit: @load_more_page_size,
              before_id: before_id,
              search_query: search_query
            )
          end

        "federated" ->
          Social.get_public_federated_posts(
            limit: @load_more_page_size,
            before_id: before_id,
            user_id: current_user && current_user.id,
            search_query: search_query
          )

        _ ->
          []
      end

    {posts, nil}
  end

  defp get_public_timeline_page(current_user, before_id, search_query) do
    if current_user do
      Social.get_public_timeline(
        limit: @load_more_page_size,
        before_id: before_id,
        user_id: current_user.id,
        search_query: search_query
      )
    else
      Social.get_public_timeline(
        limit: @load_more_page_size,
        before_id: before_id,
        search_query: search_query
      )
    end
  end

  defp special_timeline_view?(view) do
    view in ["communities", "replies", "friends", "my_posts", "trusted"]
  end

  defp append_gap_marker(existing_markers, current_posts, [first_new_post | _])
       when is_list(current_posts) and current_posts != [] do
    existing_markers
    |> normalize_gap_markers()
    |> MapSet.put(first_new_post.id)
  end

  defp append_gap_marker(existing_markers, _current_posts, _more_posts) do
    normalize_gap_markers(existing_markers)
  end

  defp normalize_gap_markers(%MapSet{} = markers), do: markers
  defp normalize_gap_markers(markers) when is_list(markers), do: MapSet.new(markers)
  defp normalize_gap_markers(_markers), do: MapSet.new()

  defp maybe_queue_reply_context_preview_fetch(socket, posts) do
    refs = ReplyContextPreviews.candidate_refs(posts)

    if refs != [] do
      send(self(), {:load_reply_context_previews, refs})
    end

    socket
  end

  defp maybe_schedule_background_refresh_jobs(socket, posts) do
    if Application.get_env(:elektrine, :environment) != :test do
      Elektrine.ActivityPub.RefreshCountsWorker.schedule_visible_refreshes(posts)
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
      Enum.each(message_ids, fn message_id ->
        _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(message_id)
      end)
    end

    socket
  end

  defp allow_timeline_read(socket, action) do
    TimelineRateLimiter.allow_read(timeline_rate_limit_identifier(socket, action))
  end

  defp event_id(value) do
    case SafeConvert.parse_id(value) do
      {:ok, id} -> id
      {:error, :invalid_id} -> 0
    end
  end

  defp handle_thread_mute(socket, message_id, action) do
    user = socket.assigns[:current_user]
    message_id = event_id(message_id)

    post =
      Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id)) ||
        Elektrine.Repo.get(Elektrine.Social.Message, message_id)

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "You must be signed in to mute conversations")}

      is_nil(post) ->
        {:noreply, put_flash(socket, :error, "Post not found")}

      action == :mute ->
        case Elektrine.Social.ThreadMutes.mute_thread(user.id, post) do
          {:ok, _} ->
            {:noreply,
             socket
             |> Helpers.touch_interaction_posts(message_id)
             |> put_flash(:info, "Conversation muted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to mute conversation")}
        end

      true ->
        _ = Elektrine.Social.ThreadMutes.unmute_thread(user.id, post)

        {:noreply,
         socket
         |> Helpers.touch_interaction_posts(message_id)
         |> put_flash(:info, "Conversation unmuted")}
    end
  end

  defp handle_user_mute(socket, user_id, action, duration) do
    user = socket.assigns[:current_user]
    target_id = event_id(user_id)

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "You must be signed in to mute users")}

      target_id <= 0 || target_id == user.id ->
        {:noreply, socket}

      action == :mute ->
        case Elektrine.Accounts.mute_user(user.id, target_id, false, mute_duration(duration)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> touch_posts_by_sender(target_id)
             |> put_flash(:info, mute_user_flash(duration))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to mute user")}
        end

      true ->
        _ = Elektrine.Accounts.unmute_user(user.id, target_id)

        {:noreply,
         socket
         |> touch_posts_by_sender(target_id)
         |> put_flash(:info, "User unmuted")}
    end
  end

  defp handle_remote_actor_mute(socket, actor_id, action) do
    user = socket.assigns[:current_user]
    actor_id = event_id(actor_id)

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "You must be signed in to mute users")}

      action == :mute ->
        case Elektrine.Accounts.mute_remote_actor(user.id, actor_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> Helpers.refresh_posts_for_remote_actor(actor_id)
             |> put_flash(:info, "User muted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to mute user")}
        end

      true ->
        _ = Elektrine.Accounts.unmute_remote_actor(user.id, actor_id)

        {:noreply,
         socket
         |> Helpers.refresh_posts_for_remote_actor(actor_id)
         |> put_flash(:info, "User unmuted")}
    end
  end

  defp touch_posts_by_sender(socket, sender_id) do
    post_ids =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(&(&1.sender_id == sender_id))
      |> Enum.map(& &1.id)

    Helpers.touch_filtered_posts(socket, post_ids)
  end

  defp mute_duration(duration) when is_binary(duration) do
    case Integer.parse(duration) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp mute_duration(_duration), do: nil

  defp mute_user_flash(duration) do
    ElektrineSocialWeb.Components.Social.TimelinePost.mute_duration_options()
    |> Enum.find_value("User muted", fn {value, label} ->
      if value == duration && value != "", do: "User muted #{String.downcase(label)}"
    end)
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

  defp timeline_path(socket, filter, view) do
    view = if filter == "rss", do: "all", else: view
    params = %{"filter" => filter, "view" => view}

    params =
      case socket.assigns[:timeline_sort] || "new" do
        "new" -> params
        sort -> Map.put(params, "sort", sort)
      end

    params =
      case socket.assigns[:search_query] do
        query when is_binary(query) ->
          if Elektrine.Strings.present?(query), do: Map.put(params, "q", query), else: params

        _ ->
          params
      end

    Elektrine.Paths.timeline_path(Enum.into(params, []))
  end

  defp parse_schedule_input_for_autosave(value) do
    case parse_schedule_input(value) do
      {:ok, scheduled_at} -> scheduled_at
      {:error, _message} -> nil
    end
  end

  defp parse_schedule_input(nil), do: {:ok, nil}
  defp parse_schedule_input(""), do: {:ok, nil}

  defp parse_schedule_input(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, nil}

      String.ends_with?(value, "Z") or String.contains?(value, "+") ->
        parse_schedule_iso8601(value)

      true ->
        parse_schedule_naive(value)
    end
  end

  defp parse_schedule_input(_value), do: {:error, "Scheduled time is invalid"}

  defp parse_schedule_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> validate_future_schedule(datetime)
      _ -> {:error, "Scheduled time is invalid"}
    end
  end

  defp parse_schedule_naive(value) do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive_datetime} ->
        naive_datetime
        |> DateTime.from_naive!("Etc/UTC")
        |> validate_future_schedule()

      _ ->
        {:error, "Scheduled time is invalid"}
    end
  end

  defp validate_future_schedule(datetime) do
    datetime = DateTime.truncate(datetime, :second)

    if DateTime.compare(datetime, DateTime.utc_now()) == :gt do
      {:ok, datetime}
    else
      {:error, "Scheduled time must be in the future"}
    end
  end

  defp format_schedule_input(nil), do: ""

  defp format_schedule_input(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  defp format_scheduled_at(nil), do: "later"

  defp format_scheduled_at(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp prune_queued_posts_for_display_toggles(socket) do
    assign(
      socket,
      :queued_posts,
      Helpers.filter_posts_by_feed_display_toggles(
        socket.assigns[:queued_posts],
        socket.assigns[:hide_boosts],
        socket.assigns[:hide_replies]
      )
    )
  end

  defp pending_media_metadata(socket) do
    case socket.assigns[:pending_media_attachments] || [] do
      [] ->
        %{}

      attachments ->
        %{"attachments" => attachments}
    end
  end

  defp draft_attachment_metadata(draft) do
    metadata = draft.media_metadata || %{}

    case Map.get(metadata, "attachments") || Map.get(metadata, :attachments) do
      attachments when is_list(attachments) -> attachments
      _ -> []
    end
  end

  defp draft_alt_texts(draft) do
    metadata = draft.media_metadata || %{}

    case Map.get(metadata, "alt_texts") || Map.get(metadata, :alt_texts) do
      alt_texts when is_map(alt_texts) -> alt_texts
      _ -> %{}
    end
  end
end
