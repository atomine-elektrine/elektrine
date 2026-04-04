defmodule ElektrineWeb.OverviewLive.Index do
  use ElektrineWeb, :live_view
  require Logger
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Messaging.Reactions
  alias Elektrine.Notifications
  alias Elektrine.Platform.Modules
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Security.SafeExternalURL
  alias ElektrineWeb.Components.Social.PostUtilities
  alias ElektrineWeb.Live.PostInteractions
  alias ElektrineWeb.Platform.Integrations
  import ElektrineWeb.Components.Platform.ENav
  import ElektrineWeb.Live.Helpers.PostStateHelpers
  @default_filter "all"
  @allowed_filters ~w(all my_posts timeline gallery discussions)
  @default_attention_filter "all"
  @allowed_attention_filters ~w(all email chat requests social system)
  @feed_load_timeout_ms 12_000
  @stats_load_timeout_ms 8000
  @dashboard_load_timeout_ms 10_000
  @session_interest_dwell_ms 10_000
  @overview_feed_limit 20
  @overview_feed_step 20
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    if user do
      locale = session["locale"] || (user && user.locale) || "en"
      Gettext.put_locale(ElektrineWeb.Gettext, locale)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "gallery:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")
        send(self(), :load_feed_data)
        send(self(), :load_stats_data)
        send(self(), :load_dashboard_data)
      end

      timezone = user.timezone || "Etc/UTC"
      time_format = user.time_format || "12"

      {:ok,
       socket
       |> assign(:page_title, "Overview")
       |> assign(:all_posts, [])
       |> assign(:filtered_all_posts, [])
       |> assign(:user_likes, %{})
       |> assign(:user_boosts, %{})
       |> assign(:user_saves, %{})
       |> assign(:user_follows, %{})
       |> assign(:pending_follows, %{})
       |> assign(:post_reactions, %{})
       |> assign(:filter, @default_filter)
       |> assign(:attention_filter, @default_attention_filter)
       |> assign(:online_users, [])
       |> assign(:user_statuses, %{})
       |> assign(:platform_stats, default_platform_stats())
       |> assign(:personal_stats, default_personal_stats())
       |> assign(:timezone, timezone)
       |> assign(:time_format, time_format)
       |> assign(:loading_feed, true)
       |> assign(:loading_stats, true)
       |> assign(:loading_dashboard, true)
       |> assign(:dashboard, default_dashboard())
       |> assign(:dashboard_last_refreshed_at, nil)
       |> assign(:data_loaded, false)
       |> assign(:visible_post_limit, @overview_feed_limit)
       |> assign(:loading_more, false)
       |> assign(:no_more_posts, false)
       |> assign(:session_context, default_session_context())
       |> assign(:feed_rerank_ref, nil)
       |> assign(:show_image_modal, false)
       |> assign(:modal_image_url, nil)
       |> assign(:modal_images, [])
       |> assign(:modal_image_index, 0)
       |> assign(:modal_post, nil)
       |> assign(:show_quote_modal, false)
       |> assign(:quote_target_post, nil)
       |> assign(:quote_content, "")}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please sign in to view your personalized overview")
       |> push_navigate(to: ~p"/login")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = normalize_filter(params["filter"])
    attention_filter = normalize_attention_filter(params["attention"])

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:attention_filter, attention_filter)

    socket =
      if socket.assigns.data_loaded do
        assign_overview_posts_for_current_filter(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = normalize_filter(filter)

    {:noreply,
     push_patch(
       socket,
       to: ~p"/overview?#{[filter: filter, attention: socket.assigns.attention_filter]}"
     )}
  end

  def handle_event("set_attention_filter", %{"filter" => filter}, socket) do
    filter = normalize_attention_filter(filter)

    {:noreply,
     push_patch(socket, to: ~p"/overview?#{[filter: socket.assigns.filter, attention: filter]}")}
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.loading_feed or socket.assigns.loading_more or socket.assigns.no_more_posts do
      {:noreply, socket}
    else
      next_limit = socket.assigns.visible_post_limit + @overview_feed_step

      {:noreply,
       socket
       |> assign(:loading_more, true)
       |> assign(:visible_post_limit, next_limit)
       |> then(fn updated_socket ->
         send(self(), {:load_more_feed, next_limit})
         updated_socket
       end)}
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id
          currently_liked = Map.get(socket.assigns.user_likes, message_id, false)
          post = find_overview_post(socket.assigns.all_posts, message_id)

          update_likes_fn = fn posts ->
            Enum.map(posts, fn post ->
              if post.id == message_id do
                if currently_liked do
                  %{post | like_count: max(0, (post.like_count || 0) - 1)}
                else
                  %{post | like_count: (post.like_count || 0) + 1}
                end
              else
                post
              end
            end)
          end

          if currently_liked do
            case Integrations.social_unlike_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_likes, &Map.put(&1, message_id, false))
                 |> update(:all_posts, update_likes_fn)
                 |> update(:filtered_all_posts, update_likes_fn)
                 |> sync_overview_posts_stream()}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unlike post")}
            end
          else
            case Integrations.social_like_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_likes, &Map.put(&1, message_id, true))
                 |> update(:all_posts, update_likes_fn)
                 |> update(:filtered_all_posts, update_likes_fn)
                 |> sync_overview_posts_stream()
                 |> note_positive_signal(post)
                 |> schedule_feed_rerank(250)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to like post")}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    end
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unlike_post", params, socket) do
    handle_event("like_post", params, socket)
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id
          currently_boosted = Map.get(socket.assigns.user_boosts, message_id, false)
          post = find_overview_post(socket.assigns.all_posts, message_id)

          update_boosts_fn = fn posts ->
            Enum.map(posts, fn post ->
              if post.id == message_id do
                if currently_boosted do
                  %{post | share_count: max(0, (post.share_count || 0) - 1)}
                else
                  %{post | share_count: (post.share_count || 0) + 1}
                end
              else
                post
              end
            end)
          end

          if currently_boosted do
            case Integrations.social_unboost_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, false))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)
                 |> sync_overview_posts_stream()}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unboost post")}
            end
          else
            case Integrations.social_boost_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, true))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)
                 |> sync_overview_posts_stream()
                 |> note_positive_signal(post)
                 |> schedule_feed_rerank(350)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to boost post")}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    end
  end

  def handle_event("unboost_post", params, socket) do
    handle_event("boost_post", params, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case Integrations.social_save_post(socket.assigns.current_user.id, message_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_saves, &Map.put(&1, message_id, true))
               |> sync_overview_posts_stream()
               |> put_flash(:info, "Saved")}

            {:error, _} ->
              {:noreply,
               socket
               |> update(:user_saves, &Map.put(&1, message_id, true))
               |> sync_overview_posts_stream()
               |> put_flash(:info, "Already saved")}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    end
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case Integrations.social_unsave_post(socket.assigns.current_user.id, message_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_saves, &Map.put(&1, message_id, false))
               |> sync_overview_posts_stream()
               |> put_flash(:info, "Removed from saved")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unsave")}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(post_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id

          existing_reaction =
            Repo.get_by(Elektrine.Messaging.MessageReaction,
              message_id: message_id,
              user_id: user_id,
              emoji: emoji
            )

          if existing_reaction do
            case Reactions.remove_reaction(message_id, user_id, emoji) do
              {:ok, _} ->
                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    message_id,
                    %{emoji: emoji, user_id: user_id},
                    :remove
                  )

                {:noreply,
                 socket
                 |> assign(:post_reactions, updated_reactions)
                 |> sync_overview_posts_stream()}

              {:error, _} ->
                {:noreply, socket}
            end
          else
            case Reactions.add_reaction(message_id, user_id, emoji) do
              {:ok, reaction} ->
                reaction = Repo.preload(reaction, [:user, :remote_actor])

                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    message_id,
                    reaction,
                    :add
                  )

                {:noreply,
                 socket
                 |> assign(:post_reactions, updated_reactions)
                 |> sync_overview_posts_stream()}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

              {:error, _} ->
                {:noreply, socket}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    end
  end

  def handle_event("react_to_post", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    handle_event("react_to_post", %{"post_id" => message_id, "emoji" => emoji}, socket)
  end

  def handle_event("quote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case Enum.find(socket.assigns.all_posts, &(&1.id == message_id)) do
            nil ->
              {:noreply, put_flash(socket, :error, "Post not found")}

            post ->
              {:noreply,
               socket
               |> assign(:show_quote_modal, true)
               |> assign(:quote_target_post, post)
               |> assign(:quote_content, "")}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    end
  end

  def handle_event("close_quote_modal", _params, socket) do
    {:noreply, close_quote_modal(socket)}
  end

  def handle_event("update_quote_content", params, socket) do
    {:noreply, assign(socket, :quote_content, params["content"] || params["value"] || "")}
  end

  def handle_event("submit_quote", params, socket) do
    content = params["content"] || params["value"] || socket.assigns.quote_content || ""

    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}

      is_nil(socket.assigns.quote_target_post) ->
        {:noreply, put_flash(socket, :error, "Quote target not found")}

      not Elektrine.Strings.present?(content) ->
        {:noreply, put_flash(socket, :error, "Please add some content to your quote")}

      true ->
        quote_target = socket.assigns.quote_target_post

        case Integrations.social_create_quote_post(
               socket.assigns.current_user.id,
               quote_target.id,
               content
             ) do
          {:ok, quote_post} ->
            reloaded_quote = reload_overview_post(quote_post.id) || quote_post

            {:noreply,
             socket
             |> increment_overview_quote_count(quote_target.id)
             |> prepend_new_post(reloaded_quote)
             |> close_quote_modal()
             |> put_flash(:info, "Quote posted!")}

          {:error, :empty_quote} ->
            {:noreply, put_flash(socket, :error, "Quote content cannot be empty")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to create quote")}
        end
    end
  end

  def handle_event("navigate_to_post", %{"id" => id} = params, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == post_id))
        post_type = params["type"] || (post && post.post_type)

        cond do
          post && post.federated && post.activitypub_id ->
            {:noreply,
             push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(post.activitypub_id)}")}

          post_type == "post" ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}

          post_type == "gallery" ->
            path =
              if post && post.activitypub_id do
                "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
              else
                ~p"/remote/post/#{post_id}"
              end

            {:noreply, push_navigate(socket, to: path)}

          post_type == "discussion" && post ->
            conversation =
              if Ecto.assoc_loaded?(post.conversation) do
                post.conversation
              else
                Elektrine.Repo.get(Messaging.Conversation, post.conversation_id)
              end

            if conversation do
              {:noreply,
               push_navigate(socket, to: ~p"/communities/#{conversation.name}/post/#{post_id}")}
            else
              {:noreply, socket}
            end

          true ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => _id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{encode_remote_post_ref(url)}")}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} -> {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("navigate_to_remote_post", %{"id" => _id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{encode_remote_post_ref(url)}")}
  end

  def handle_event("navigate_to_remote_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{encode_remote_post_ref(url)}")}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} -> {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post && post.federated && post.activitypub_id do
          {:noreply,
           push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(post.activitypub_id)}")}
        else
          {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message_id}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    with {:ok, decoded_images} <- Jason.decode(images_json),
         true <- is_list(decoded_images) and decoded_images != [] do
      images = Enum.filter(decoded_images, &is_binary/1)
      index_int = parse_non_negative_int(index, 0) |> min(max(length(images) - 1, 0))
      url = params["url"] || Enum.at(images, index_int, List.first(images))

      modal_post =
        case params["post_id"] do
          nil ->
            nil

          post_id ->
            case parse_positive_int(post_id) do
              {:ok, id} ->
                Enum.find(socket.assigns.filtered_all_posts, fn post -> post.id == id end)

              :error ->
                nil
            end
        end

      {:noreply,
       socket
       |> assign(:show_image_modal, true)
       |> assign(:modal_image_url, url)
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, index_int)
       |> assign(:modal_post, modal_post)}
    else
      _ -> {:noreply, socket}
    end
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

  def handle_event("next_image", _params, socket) do
    total = length(socket.assigns.modal_images)

    if total > 0 do
      new_index = rem(socket.assigns.modal_image_index + 1, total)
      new_url = Enum.at(socket.assigns.modal_images, new_index)

      {:noreply,
       socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)

    if total > 0 do
      new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
      new_url = Enum.at(socket.assigns.modal_images, new_index)

      {:noreply,
       socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("next_media_post", _params, socket) do
    navigate_to_media_post(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_post(socket, :prev)
  end

  def handle_event("view_post", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post do
          path =
            case post.post_type do
              "gallery" ->
                if post.activitypub_id do
                  "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
                else
                  ~p"/remote/post/#{message_id}"
                end

              _ ->
                ~p"/timeline/post/#{message_id}"
            end

          {:noreply, push_navigate(socket, to: path)}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_post_link", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post do
          path =
            case post.post_type do
              "discussion" ->
                "/posts/#{message_id}"

              "gallery" ->
                if post.activitypub_id do
                  "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
                else
                  "/remote/post/#{message_id}"
                end

              _ ->
                "/timeline/post/#{message_id}"
            end

          url = ElektrineWeb.Endpoint.url() <> path
          {:noreply, push_event(socket, "copy_to_clipboard", %{text: url})}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_post", %{"message_id" => message_id}, socket) do
    user = socket.assigns.current_user

    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        case Messaging.get_message(message_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Post not found")}

          message ->
            if message.sender_id == user.id do
              case Messaging.Messages.delete_message(message_id, user.id) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> update(:all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> update(:filtered_all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> sync_overview_posts_stream()
                   |> put_flash(:info, "Post deleted")}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to delete post")}
              end
            else
              {:noreply, put_flash(socket, :error, "You can only delete your own posts")}
            end
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid post id")}
    end
  end

  def handle_event("navigate_to_embedded_post", %{"message_id" => message_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message_id}")}
  end

  def handle_event("open_external_link", %{"url" => url}, socket) do
    {:noreply, redirect_to_external_url(socket, url)}
  end

  def handle_event("toggle_follow", %{"user_id" => user_id}, socket) do
    case parse_positive_int(user_id) do
      {:ok, user_id} ->
        current_user = socket.assigns.current_user
        is_following = Map.get(socket.assigns.user_follows, {:local, user_id}, false)

        if is_following do
          case Integrations.social_unfollow_user(current_user.id, user_id) do
            {:ok, :unfollowed} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:local, user_id}, false))
               |> sync_overview_posts_stream()}

            {:ok, :not_following} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:local, user_id}, false))
               |> sync_overview_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unfollow user")}
          end
        else
          case Integrations.social_follow_user(current_user.id, user_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:local, user_id}, true))
               |> sync_overview_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to follow user")}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_follow_remote", %{"actor_id" => actor_id}, socket) do
    case parse_positive_int(actor_id) do
      {:ok, actor_id} ->
        current_user = socket.assigns.current_user
        is_following = Map.get(socket.assigns.user_follows, {:remote, actor_id}, false)

        if is_following do
          case Elektrine.Profiles.unfollow_remote_actor(current_user.id, actor_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, false))
               |> sync_overview_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unfollow")}
          end
        else
          case Elektrine.Profiles.follow_remote_actor(current_user.id, actor_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, true))
               |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, true))
               |> sync_overview_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to follow")}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("report_post", _params, socket) do
    {:noreply, put_flash(socket, :info, "Report feature coming soon")}
  end

  def handle_event("delete_post_admin", _params, socket) do
    {:noreply, put_flash(socket, :error, "Admin actions not available here")}
  end

  def handle_event("not_interested", %{"post_id" => post_id}, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user && post_id do
        Integrations.overview_record_dismissal(user.id, post_id, "not_interested", nil)

        socket
        |> note_dismissal_signal(post_id)
        |> remove_overview_post(post_id)
        |> schedule_feed_rerank(150)
        |> put_flash(:info, "We’ll show less like this.")
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("hide_post", %{"post_id" => post_id}, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user && post_id do
        Integrations.overview_record_dismissal(user.id, post_id, "hidden", nil)

        socket
        |> note_dismissal_signal(post_id)
        |> remove_overview_post(post_id)
        |> schedule_feed_rerank(150)
        |> put_flash(:info, "Post hidden from your overview.")
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("record_dwell_time", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        post_id = params["post_id"]

        if post_id do
          attrs = %{
            dwell_time_ms: params["dwell_time_ms"],
            scroll_depth: params["scroll_depth"],
            expanded: params["expanded"] || false,
            source: params["source"] || "overview"
          }

          Integrations.overview_record_view_with_dwell(user.id, post_id, attrs)

          socket
          |> note_view_signal(post_id, params["dwell_time_ms"])
          |> maybe_note_dwell_interest(post_id, params["dwell_time_ms"])
        else
          socket
        end
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("record_dwell_times", %{"views" => views}, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        Enum.reduce(views, socket, fn view, acc ->
          post_id = view["post_id"]

          if post_id do
            attrs = %{
              dwell_time_ms: view["dwell_time_ms"],
              scroll_depth: view["scroll_depth"],
              expanded: view["expanded"] || false,
              source: view["source"] || "overview"
            }

            Integrations.overview_record_view_with_dwell(user.id, post_id, attrs)

            acc
            |> note_view_signal(post_id, view["dwell_time_ms"])
            |> maybe_note_dwell_interest(post_id, view["dwell_time_ms"])
          else
            acc
          end
        end)
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("record_dismissal", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        post_id = params["post_id"]
        type = params["type"]
        dwell_time_ms = params["dwell_time_ms"]

        if post_id && type do
          Integrations.overview_record_dismissal(user.id, post_id, type, dwell_time_ms)

          socket
          |> note_dismissal_signal(post_id)
        else
          socket
        end
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("update_session_context", params, socket) do
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators

    session_context = %{
      (socket.assigns[:session_context] || default_session_context())
      | liked_hashtags:
          merge_recent_unique(
            socket.assigns[:session_context][:liked_hashtags],
            params["liked_hashtags"] || [],
            20
          ),
        liked_creators: merge_recent_unique([], liked_creators, 10),
        liked_local_creators:
          merge_recent_unique(
            socket.assigns[:session_context][:liked_local_creators],
            liked_local_creators,
            10
          ),
        liked_remote_creators:
          merge_recent_unique(
            socket.assigns[:session_context][:liked_remote_creators],
            params["liked_remote_creators"] || [],
            10
          ),
        viewed_posts:
          merge_recent_unique(
            socket.assigns[:session_context][:viewed_posts],
            params["viewed_posts"] || [],
            50
          ),
        engagement_rate:
          coerce_float(
            params["engagement_rate"],
            socket.assigns[:session_context][:engagement_rate] || 0.0
          )
    }

    {:noreply, assign(socket, :session_context, session_context)}
  end

  def handle_event("", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    posts = socket.assigns[:filtered_all_posts] || []

    if is_nil(modal_post) or Enum.empty?(posts) do
      {:noreply, socket}
    else
      media_posts =
        Enum.filter(posts, fn post ->
          media_urls = post.media_urls || []
          media_urls != []
        end)

      current_index = Enum.find_index(media_posts, fn post -> post.id == modal_post.id end)

      if is_nil(current_index) do
        {:noreply, socket}
      else
        total = length(media_posts)

        new_index =
          case direction do
            :next -> rem(current_index + 1, total)
            :prev -> rem(current_index - 1 + total, total)
          end

        new_post = Enum.at(media_posts, new_index)
        new_images = new_post.media_urls || []
        new_url = List.first(new_images)

        {:noreply,
         socket
         |> assign(:modal_post, new_post)
         |> assign(:modal_images, new_images)
         |> assign(:modal_image_index, 0)
         |> assign(:modal_image_url, new_url)}
      end
    end
  end

  @impl true
  def handle_info({:new_timeline_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:new_gallery_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:new_discussion_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile], conversation: [])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    update_fn = fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)
    end

    {:noreply,
     socket
     |> update(:all_posts, update_fn)
     |> update(:filtered_all_posts, update_fn)
     |> sync_overview_posts_stream()}
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    update_fn = fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }
        else
          post
        end
      end)
    end

    updated_modal_post =
      case socket.assigns[:modal_post] do
        %{id: ^message_id} = post ->
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }

        post ->
          post
      end

    {:noreply,
     socket
     |> update(:all_posts, update_fn)
     |> update(:filtered_all_posts, update_fn)
     |> assign(:modal_post, updated_modal_post)
     |> sync_overview_posts_stream()}
  end

  def handle_info(:load_dashboard_data, socket) do
    user = socket.assigns.current_user

    case load_with_timeout(
           :dashboard_data,
           fn -> build_dashboard_data(user) end,
           @dashboard_load_timeout_ms
         ) do
      {:ok, dashboard} ->
        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:loading_dashboard, false)
         |> assign(:dashboard_last_refreshed_at, DateTime.utc_now())}

      {:error, _reason} ->
        {:noreply,
         socket |> assign(:dashboard, default_dashboard()) |> assign(:loading_dashboard, false)}
    end
  end

  def handle_info(:load_feed_data, socket) do
    {:noreply, load_feed_data(socket, socket.assigns.visible_post_limit)}
  end

  def handle_info({:load_more_feed, limit}, socket) do
    {:noreply, load_feed_data(socket, limit)}
  end

  def handle_info(:refresh_feed_ranking, socket) do
    socket = assign(socket, :feed_rerank_ref, nil)

    if is_nil(socket.assigns[:current_user]) or socket.assigns.loading_feed or
         !socket.assigns.data_loaded do
      {:noreply, socket}
    else
      case load_with_timeout(
             :for_you_feed_rerank,
             fn ->
               Integrations.overview_for_you_feed(
                 socket.assigns.current_user.id,
                 limit: socket.assigns.visible_post_limit,
                 session_context: socket.assigns[:session_context] || %{}
               )
               |> build_feed_state(socket.assigns.current_user.id)
             end,
             4000
           ) do
        {:ok, feed_data} ->
          {:noreply, assign_feed_data(socket, feed_data)}

        {:error, _reason} ->
          {:noreply, socket}
      end
    end
  end

  def handle_info(:load_stats_data, socket) do
    user = socket.assigns.current_user

    platform_stats =
      case load_with_timeout(
             :platform_stats,
             fn -> get_platform_stats() end,
             @stats_load_timeout_ms
           ) do
        {:ok, stats} -> stats
        {:error, _reason} -> default_platform_stats()
      end

    personal_stats =
      case load_with_timeout(
             :personal_stats,
             fn -> get_personal_stats(user.id) end,
             @stats_load_timeout_ms
           ) do
        {:ok, stats} -> stats
        {:error, _reason} -> default_personal_stats()
      end

    {:noreply,
     socket
     |> assign(:platform_stats, platform_stats)
     |> assign(:personal_stats, personal_stats)
     |> assign(:loading_stats, false)}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  defp get_user_likes_map(user_id, posts) do
    get_user_likes(user_id, posts)
  end

  defp get_user_boosts_map(user_id, posts) do
    get_user_boosts(user_id, posts)
  end

  defp default_dashboard do
    %{
      inbox_messages: [],
      inbox_unread_count: 0,
      chat_unread_count: 0,
      notifications_unread_count: 0,
      pending_friend_requests_count: 0,
      pending_follow_requests_count: 0,
      vpn_config_count: 0,
      tasks: [],
      alerts: [],
      attention_queue: [],
      attention_counts: %{"all" => 0},
      quick_actions: quick_actions(),
      recent_activity: []
    }
  end

  defp quick_actions do
    [
      if Modules.enabled?(:email) do
        %{
          id: "compose_email",
          label: "Compose Email",
          detail: "Start a new message",
          href: ~p"/email/compose?return_to=overview",
          icon: "hero-pencil-square",
          tone: "primary"
        }
      end,
      if Modules.enabled?(:chat) do
        %{
          id: "new_message",
          label: "New Message",
          detail: "Start a direct message",
          href: ~p"/chat?#{[composer: "message"]}",
          icon: "hero-chat-bubble-left-right",
          tone: "neutral"
        }
      end,
      if Modules.enabled?(:social) do
        %{
          id: "new_post",
          label: "New Post",
          detail: "Share an update",
          href: ~p"/timeline?#{[composer: "post"]}",
          icon: "hero-rectangle-stack",
          tone: "neutral"
        }
      end,
      if Modules.enabled?(:email) do
        %{
          id: "new_task",
          label: "New Task",
          detail: "Capture work on the calendar",
          href: ~p"/calendar?#{[composer: "task"]}",
          icon: "hero-check-circle",
          tone: "neutral"
        }
      end,
      if Modules.enabled?(:social) do
        %{
          id: "new_list",
          label: "New List",
          detail: "Save a smaller group",
          href: "/lists#create-list-panel",
          icon: "hero-queue-list",
          tone: "neutral"
        }
      end,
      %{
        id: "search",
        label: "Global Search",
        detail: "Jump across the workspace",
        href: ~p"/search",
        icon: "hero-magnifying-glass",
        tone: "neutral"
      }
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_dashboard_data(user) do
    mailbox = Integrations.email_mailbox(user.id)

    {inbox_messages, inbox_unread_count, reply_later_count} =
      if mailbox do
        dashboard = Integrations.overview_email_dashboard(user.id)
        {dashboard.inbox_messages, dashboard.inbox_unread_count, dashboard.reply_later_count}
      else
        {[], 0, 0}
      end

    chat_unread_count = Messaging.get_unread_count(user.id)
    recent_conversations = Messaging.list_conversations(user.id, limit: 3)
    notifications_unread_count = Notifications.get_unread_count(user.id)
    recent_notifications = Notifications.list_notifications(user.id, filter: :unread, limit: 8)
    pending_friend_requests = Friends.list_pending_requests(user.id)
    pending_follow_requests = Profiles.get_pending_follow_requests(user.id)
    vpn_configs = Integrations.vpn_user_configs(user.id)
    recent_posts = Integrations.overview_recent_posts(user.id, limit: 3)
    pending_friend_requests_count = length(pending_friend_requests)
    pending_follow_requests_count = length(pending_follow_requests)
    vpn_config_count = length(vpn_configs)

    tasks =
      build_dashboard_tasks(
        inbox_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count,
        vpn_config_count
      )

    alerts =
      build_dashboard_alerts(
        inbox_unread_count,
        notifications_unread_count,
        chat_unread_count,
        pending_follow_requests_count
      )

    attention_queue =
      build_attention_queue(
        inbox_messages,
        recent_notifications,
        inbox_unread_count,
        notifications_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count
      )

    %{
      inbox_messages: inbox_messages,
      inbox_unread_count: inbox_unread_count,
      chat_unread_count: chat_unread_count,
      notifications_unread_count: notifications_unread_count,
      pending_friend_requests_count: pending_friend_requests_count,
      pending_follow_requests_count: pending_follow_requests_count,
      vpn_config_count: vpn_config_count,
      tasks: tasks,
      alerts: alerts,
      attention_queue: attention_queue,
      attention_counts: attention_queue_counts(attention_queue),
      quick_actions: quick_actions(),
      recent_activity:
        build_recent_activity(
          inbox_messages,
          recent_conversations,
          recent_posts,
          recent_notifications,
          vpn_configs
        )
    }
  end

  defp build_dashboard_tasks(
         inbox_unread_count,
         reply_later_count,
         chat_unread_count,
         pending_friend_requests_count,
         pending_follow_requests_count,
         vpn_config_count
       ) do
    [
      if inbox_unread_count > 0 do
        %{
          id: "review_inbox",
          title: "Review unread inbox",
          detail: "#{inbox_unread_count} message(s) waiting",
          href: ~p"/email?tab=inbox&filter=unread",
          icon: "hero-envelope",
          priority: "high"
        }
      end,
      if reply_later_count > 0 do
        %{
          id: "reply_later",
          title: "Handle boomerang reminders",
          detail: "#{reply_later_count} follow-up reminder(s)",
          href: ~p"/email?tab=inbox&filter=boomerang",
          icon: "hero-arrow-uturn-left",
          priority: "medium"
        }
      end,
      if pending_friend_requests_count > 0 do
        %{
          id: "friend_requests",
          title: "Respond to friend requests",
          detail: "#{pending_friend_requests_count} pending request(s)",
          href: ~p"/friends?tab=requests",
          icon: "hero-user-plus",
          priority: "medium"
        }
      end,
      if pending_follow_requests_count > 0 do
        %{
          id: "follow_requests",
          title: "Review fediverse follows",
          detail: "#{pending_follow_requests_count} remote request(s)",
          href: ~p"/friends?tab=requests",
          icon: "hero-globe-americas",
          priority: "high"
        }
      end,
      if chat_unread_count > 0 do
        %{
          id: "chat_unread",
          title: "Catch up on chat",
          detail: "#{chat_unread_count} unread chat message(s)",
          href: ~p"/chat",
          icon: "hero-chat-bubble-left-right",
          priority: "medium"
        }
      end,
      if Modules.enabled?(:vpn) and vpn_config_count == 0 do
        %{
          id: "vpn_setup",
          title: "Create your first VPN config",
          detail: "Protect your traffic before browsing",
          href: ~p"/vpn",
          icon: "hero-shield-check",
          priority: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_dashboard_alerts(
         inbox_unread_count,
         notifications_unread_count,
         chat_unread_count,
         pending_follow_requests_count
       ) do
    [
      if pending_follow_requests_count > 0 do
        %{
          id: "fediverse_follow_requests",
          title: "Pending fediverse follow approvals",
          detail: "#{pending_follow_requests_count} request(s) are waiting",
          href: ~p"/friends?tab=requests",
          icon: "hero-globe-americas",
          level: "high"
        }
      end,
      if notifications_unread_count >= 15 do
        %{
          id: "notification_backlog",
          title: "Notification backlog building up",
          detail: "#{notifications_unread_count} unread notifications",
          href: ~p"/notifications",
          icon: "hero-bell-alert",
          level: "medium"
        }
      end,
      if inbox_unread_count >= 25 do
        %{
          id: "inbox_backlog",
          title: "Inbox backlog is growing",
          detail: "#{inbox_unread_count} unread inbox messages",
          href: ~p"/email?tab=inbox&filter=unread",
          icon: "hero-envelope",
          level: "medium"
        }
      end,
      if chat_unread_count >= 20 do
        %{
          id: "chat_backlog",
          title: "Chat backlog is growing",
          detail: "#{chat_unread_count} unread chat messages",
          href: ~p"/chat",
          icon: "hero-chat-bubble-left-right",
          level: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_attention_queue(
         inbox_messages,
         recent_notifications,
         inbox_unread_count,
         notifications_unread_count,
         reply_later_count,
         chat_unread_count,
         pending_friend_requests_count,
         pending_follow_requests_count
       ) do
    unread_email_messages =
      inbox_messages
      |> Enum.filter(&(Map.get(&1, :read, false) == false))
      |> Enum.take(3)

    remaining_unread_count = max(inbox_unread_count - length(unread_email_messages), 0)

    remaining_notification_count =
      max(notifications_unread_count - min(length(recent_notifications), 4), 0)

    unread_email_items = Enum.map(unread_email_messages, &build_unread_email_attention_item/1)

    request_items =
      [
        if pending_friend_requests_count > 0 do
          %{
            id: "attention-friend-requests",
            source: "requests",
            title: "Respond to friend requests",
            detail: "#{pending_friend_requests_count} request(s) waiting",
            href: ~p"/friends?tab=requests",
            icon: "hero-user-plus",
            priority: "high",
            state: "pending",
            at: nil,
            actions: [
              attention_action("Open", ~p"/friends?tab=requests"),
              attention_action("Follow", ~p"/friends?tab=requests")
            ]
          }
        end,
        if pending_follow_requests_count > 0 do
          %{
            id: "attention-follow-requests",
            source: "requests",
            title: "Review fediverse follow approvals",
            detail: "#{pending_follow_requests_count} approval(s) waiting",
            href: ~p"/friends?tab=requests",
            icon: "hero-globe-americas",
            priority: "high",
            state: "approval",
            at: nil,
            actions: [
              attention_action("Open", ~p"/friends?tab=requests"),
              attention_action("Follow", ~p"/friends?tab=requests")
            ]
          }
        end
      ]

    backlog_items =
      [
        if remaining_unread_count > 0 do
          %{
            id: "attention-more-email",
            source: "email",
            title: "More unread email waiting",
            detail: "#{remaining_unread_count} more unread message(s)",
            href: ~p"/email?tab=inbox&filter=unread",
            icon: "hero-envelope",
            priority: "high",
            state: "backlog",
            at: nil,
            actions: [
              attention_action("Open", ~p"/email?tab=inbox&filter=unread"),
              attention_action("Move", ~p"/email?tab=inbox")
            ]
          }
        end,
        if reply_later_count > 0 do
          %{
            id: "attention-reply-later",
            source: "email",
            title: "Handle reply-later reminders",
            detail: "#{reply_later_count} reminder(s) due",
            href: ~p"/email?tab=inbox&filter=boomerang",
            icon: "hero-arrow-uturn-left",
            priority: "medium",
            state: "remind",
            at: nil,
            actions: [
              attention_action("Open", ~p"/email?tab=inbox&filter=boomerang"),
              attention_action("Remind", ~p"/email?tab=inbox&filter=boomerang")
            ]
          }
        end,
        if chat_unread_count > 0 do
          %{
            id: "attention-chat-unread",
            source: "chat",
            title: "Catch up on chat",
            detail: "#{chat_unread_count} unread message(s)",
            href: ~p"/chat",
            icon: "hero-chat-bubble-left-right",
            priority: "medium",
            state: "unread",
            at: nil,
            actions: [attention_action("Open", ~p"/chat")]
          }
        end,
        if remaining_notification_count > 0 do
          %{
            id: "attention-more-notifications",
            source: "social",
            title: "More notifications are stacked up",
            detail:
              "#{remaining_notification_count} unread notification(s) behind the latest items",
            href: ~p"/notifications",
            icon: "hero-bell-alert",
            priority: "medium",
            state: "backlog",
            at: nil,
            actions: [attention_action("Open", ~p"/notifications")]
          }
        end
      ]

    notification_items =
      recent_notifications
      |> Enum.take(4)
      |> Enum.map(&build_notification_attention_item/1)

    (unread_email_items ++ request_items ++ backlog_items ++ notification_items)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn item ->
      {attention_priority_rank(item.priority), -sort_datetime(item.at)}
    end)
    |> Enum.take(12)
  end

  defp build_unread_email_attention_item(message) do
    href = ~p"/email/view/#{message.hash || message.id}"

    %{
      id: "attention-email-#{message.id}",
      source: "email",
      title: inbox_subject(message),
      detail: "From #{inbox_sender(message.from)}",
      href: href,
      icon: "hero-envelope",
      priority: "high",
      state: "unread",
      at: message.inserted_at,
      actions: [
        attention_action("Open", href),
        attention_action("Move", ~p"/email?tab=inbox"),
        attention_action("Remind", ~p"/email?tab=inbox&filter=boomerang")
      ]
    }
  end

  defp build_notification_attention_item(notification) do
    source = notification_attention_source(notification)
    href = normalize_internal_path(notification.url)

    %{
      id: "attention-notification-#{notification.id}",
      source: source,
      title: trim_or(notification.title, "Notification"),
      detail: notification_activity_detail(notification),
      href: href,
      icon: notification_activity_icon(notification),
      priority: notification_attention_priority(notification),
      state: "unread",
      at: notification.inserted_at,
      actions: attention_actions_for_source(source, href)
    }
  end

  defp attention_actions_for_source("email", href) do
    [
      attention_action("Open", href),
      attention_action("Move", ~p"/email?tab=inbox"),
      attention_action("Remind", ~p"/email?tab=inbox&filter=boomerang")
    ]
  end

  defp attention_actions_for_source("requests", href) do
    [attention_action("Open", href), attention_action("Follow", href)]
  end

  defp attention_actions_for_source("social", href) do
    [
      attention_action("Open", href),
      attention_action("Save", ~p"/timeline?filter=saved&view=all"),
      attention_action("Share", ~p"/timeline?#{[composer: "post"]}")
    ]
  end

  defp attention_actions_for_source(_source, href) do
    [attention_action("Open", href)]
  end

  defp attention_action(label, href), do: %{label: label, href: href}

  defp attention_queue_counts(queue) do
    base_counts =
      Enum.reduce(@allowed_attention_filters, %{}, fn filter, acc ->
        Map.put(acc, filter, 0)
      end)

    queue
    |> Enum.reduce(base_counts, fn item, acc ->
      Map.update(acc, item.source, 1, &(&1 + 1))
    end)
    |> Map.put("all", length(queue))
  end

  defp filtered_attention_queue(queue, "all"), do: queue

  defp filtered_attention_queue(queue, filter) do
    Enum.filter(queue, &(&1.source == filter))
  end

  defp normalize_attention_filter(filter) when filter in @allowed_attention_filters, do: filter
  defp normalize_attention_filter(_filter), do: @default_attention_filter

  defp attention_filter_label("all"), do: "All"
  defp attention_filter_label("email"), do: "Email"
  defp attention_filter_label("chat"), do: "Chat"
  defp attention_filter_label("requests"), do: "Requests"
  defp attention_filter_label("social"), do: "Social"
  defp attention_filter_label("system"), do: "System"
  defp attention_filter_label(filter), do: String.capitalize(filter)

  defp attention_source_badge_class("email"), do: "badge badge-info badge-xs"
  defp attention_source_badge_class("chat"), do: "badge badge-primary badge-xs"
  defp attention_source_badge_class("requests"), do: "badge badge-warning badge-xs"
  defp attention_source_badge_class("social"), do: "badge badge-secondary badge-xs"
  defp attention_source_badge_class(_source), do: "badge badge-ghost badge-xs"

  defp attention_state_badge_class("unread"), do: "badge badge-primary badge-xs"
  defp attention_state_badge_class("pending"), do: "badge badge-warning badge-xs"
  defp attention_state_badge_class("approval"), do: "badge badge-warning badge-xs"
  defp attention_state_badge_class("backlog"), do: "badge badge-error badge-xs"
  defp attention_state_badge_class("remind"), do: "badge badge-info badge-xs"
  defp attention_state_badge_class(_state), do: "badge badge-ghost badge-xs"

  defp attention_action_link_class do
    "link link-hover text-xs text-base-content/70"
  end

  defp attention_priority_rank("high"), do: 0
  defp attention_priority_rank("medium"), do: 1
  defp attention_priority_rank(_priority), do: 2

  defp notification_attention_source(notification) do
    case {notification.type, notification.source_type} do
      {"email_received", _} -> "email"
      {_, "message"} -> "chat"
      {_, "post"} -> "social"
      {_, "discussion"} -> "social"
      {"follow", _} -> "social"
      {"mention", _} -> "social"
      _ -> "system"
    end
  end

  defp notification_attention_priority(notification) do
    case notification.type do
      "mention" -> "high"
      "reply" -> "high"
      "email_received" -> "medium"
      "new_message" -> "medium"
      "follow" -> "medium"
      _ -> "low"
    end
  end

  defp build_recent_activity(
         inbox_messages,
         recent_conversations,
         recent_posts,
         recent_notifications,
         vpn_configs
       ) do
    email_items =
      inbox_messages
      |> Enum.take(3)
      |> Enum.map(fn message ->
        %{
          id: "email-#{message.id}",
          app: "Email",
          title: inbox_subject(message),
          detail: "From #{inbox_sender(message.from)}",
          href: ~p"/email/view/#{message.hash || message.id}",
          icon: "hero-envelope",
          at: message.inserted_at
        }
      end)

    chat_items =
      recent_conversations
      |> Enum.take(3)
      |> Enum.map(fn conversation ->
        %{
          id: "chat-#{conversation.id}",
          app: "Chat",
          title: conversation_label(conversation),
          detail: String.capitalize(conversation.type || "conversation"),
          href: ~p"/chat/#{conversation.hash || conversation.id}",
          icon: "hero-chat-bubble-left-right",
          at: conversation.last_message_at || conversation.updated_at || conversation.inserted_at
        }
      end)

    social_items =
      recent_posts
      |> Enum.take(3)
      |> Enum.map(fn post ->
        %{
          id: "social-#{post.id}",
          app: "Social",
          title: social_post_title(post),
          detail: "Timeline update",
          href: ~p"/timeline/post/#{post.id}",
          icon: "hero-rectangle-stack",
          at: post.inserted_at
        }
      end)

    notification_items =
      recent_notifications
      |> Enum.take(3)
      |> Enum.map(fn notification ->
        %{
          id: "notification-#{notification.id}",
          app: notification_activity_app(notification),
          title: trim_or(notification.title, "Notification"),
          detail: notification_activity_detail(notification),
          href: normalize_internal_path(notification.url),
          icon: notification_activity_icon(notification),
          at: notification.inserted_at
        }
      end)

    vpn_items =
      case Enum.max_by(vpn_configs, &sort_datetime(&1.updated_at || &1.inserted_at), fn -> nil end) do
        nil ->
          []

        config ->
          [
            %{
              id: "vpn-#{config.id}",
              app: "VPN",
              title: "VPN profile ready",
              detail: trim_or(config.vpn_server && config.vpn_server.name, "WireGuard config"),
              href: ~p"/vpn",
              icon: "hero-shield-check",
              at: config.updated_at || config.inserted_at
            }
          ]
      end

    (email_items ++ chat_items ++ social_items ++ notification_items ++ vpn_items)
    |> Enum.sort_by(&sort_datetime(&1.at), :desc)
    |> Enum.take(10)
  end

  defp trim_or(value, fallback) when is_binary(value) do
    value = String.trim(value)

    Elektrine.Strings.present(value) || fallback
  end

  defp trim_or(_value, fallback) do
    fallback
  end

  defp inbox_subject(%{subject: subject}) when is_binary(subject) do
    subject |> trim_or("(No subject)") |> truncate_text(72)
  end

  defp inbox_subject(_) do
    "(No subject)"
  end

  defp inbox_sender(from) do
    from |> trim_or("Unknown sender") |> extract_sender_name() |> truncate_text(42)
  end

  defp extract_sender_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<(.+)>$/, from) do
      [_, name, _email] -> name |> String.trim() |> String.trim("\"") |> trim_or(from)
      _ -> from
    end
  end

  defp extract_sender_name(from) do
    from
  end

  defp truncate_text(text, max_length) when is_binary(text) and max_length > 1 do
    if String.length(text) > max_length do
      if max_length <= 3 do
        String.slice(text, 0, max_length)
      else
        String.slice(text, 0, max_length - 3) <> "..."
      end
    else
      text
    end
  end

  defp truncate_text(_text, _max_length) do
    ""
  end

  defp conversation_label(conversation) do
    name = trim_or(conversation.name, "")

    cond do
      Elektrine.Strings.present?(name) -> name
      conversation.type == "dm" -> "Direct message"
      true -> "Conversation ##{conversation.id}"
    end
  end

  defp social_post_title(post) do
    post
    |> then(fn post ->
      ElektrineWeb.HtmlHelpers.plain_text_content(post.title || post.content)
    end)
    |> trim_or("New social post")
    |> truncate_text(72)
  end

  defp notification_activity_app(notification) do
    case {notification.type, notification.source_type} do
      {"email_received", _} -> "Email"
      {_, "message"} -> "Chat"
      {_, "post"} -> "Social"
      {_, "discussion"} -> "Social"
      {"follow", _} -> "Social"
      {"mention", _} -> "Social"
      _ -> "Alerts"
    end
  end

  defp notification_activity_icon(notification) do
    case notification.type do
      "email_received" -> "hero-envelope"
      "new_message" -> "hero-chat-bubble-left-right"
      "reply" -> "hero-chat-bubble-left"
      "follow" -> "hero-user-plus"
      "mention" -> "hero-at-symbol"
      "like" -> "hero-heart"
      _ -> "hero-bell"
    end
  end

  defp notification_activity_detail(notification) do
    trim_or(notification.body, "Recent update") |> truncate_text(90)
  end

  defp normalize_internal_path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/") do
      path
    else
      ~p"/notifications"
    end
  end

  defp normalize_internal_path(_) do
    ~p"/notifications"
  end

  defp sort_datetime(%DateTime{} = datetime) do
    DateTime.to_unix(datetime)
  end

  defp sort_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC") |> DateTime.to_unix()
  end

  defp sort_datetime(_) do
    0
  end

  defp quick_action_button_class("primary") do
    "btn btn-sm btn-secondary"
  end

  defp quick_action_button_class(_tone) do
    "btn btn-sm btn-ghost border border-base-300"
  end

  defp task_priority_badge_class("high") do
    "badge badge-error badge-xs"
  end

  defp task_priority_badge_class("medium") do
    "badge badge-warning badge-xs"
  end

  defp task_priority_badge_class(_priority) do
    "badge badge-ghost badge-xs"
  end

  defp filtered_posts(posts, "timeline", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "post" end)
  end

  defp filtered_posts(posts, "gallery", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "gallery" end)
  end

  defp filtered_posts(posts, "discussions", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "discussion" end)
  end

  defp filtered_posts(posts, "my_posts", %{current_user: user}) do
    Enum.filter(posts, fn post -> post.sender_id == user.id end)
  end

  defp filtered_posts(posts, _, _assigns) do
    posts
  end

  defp normalize_filter(filter) when is_binary(filter) and filter in @allowed_filters do
    filter
  end

  defp normalize_filter(_) do
    @default_filter
  end

  defp base_posts_for_filter("my_posts", %{current_user: user}) do
    get_user_own_posts(user.id)
  end

  defp base_posts_for_filter(_filter, %{all_posts: posts}) do
    posts
  end

  defp prepend_new_post(socket, post) do
    socket =
      socket
      |> register_post_state(post)
      |> update(:all_posts, &prepend_and_cap_overview_posts(&1, post))

    case socket.assigns.filter do
      "my_posts" ->
        current_user = socket.assigns[:current_user]

        if current_user && post.sender_id == current_user.id do
          socket
          |> update(:filtered_all_posts, &prepend_and_cap_overview_posts(&1, post))
          |> sync_overview_posts_stream()
        else
          socket
        end

      _ ->
        socket
        |> assign(:filtered_all_posts, socket.assigns.all_posts)
        |> sync_overview_posts_stream()
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_int(_) do
    :error
  end

  defp encode_remote_post_ref(ref) when is_binary(ref) do
    normalized_ref =
      ref
      |> String.trim()
      |> decode_remote_post_ref()

    URI.encode_www_form(normalized_ref)
  end

  defp encode_remote_post_ref(ref), do: URI.encode_www_form(to_string(ref))

  defp decode_remote_post_ref(ref) when is_binary(ref) do
    URI.decode_www_form(ref)
  rescue
    ArgumentError -> ref
  end

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0 do
    value
  end

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_, default) do
    default
  end

  defp assign_feed_data(socket, feed_data) do
    socket
    |> assign(:all_posts, feed_data.all_posts || [])
    |> assign(:user_likes, feed_data.user_likes)
    |> assign(:user_boosts, feed_data.user_boosts)
    |> assign(:user_saves, feed_data.user_saves)
    |> assign(:user_follows, feed_data.user_follows)
    |> assign(:pending_follows, feed_data.pending_follows)
    |> assign(:post_reactions, feed_data.post_reactions)
    |> assign(:loading_feed, false)
    |> assign(:data_loaded, true)
    |> assign_overview_posts_for_current_filter()
  end

  defp assign_overview_posts_for_current_filter(socket) do
    base_posts = socket.assigns.filter |> base_posts_for_filter(socket.assigns)

    socket
    |> assign(:filtered_all_posts, base_posts)
    |> sync_overview_posts_stream()
  end

  defp sync_overview_posts_stream(socket) do
    filtered_posts_for_view =
      socket.assigns.filtered_all_posts
      |> filtered_posts(socket.assigns.filter, socket.assigns)
      |> maybe_group_reply_chains(socket)

    no_more_posts = length(filtered_posts_for_view) < socket.assigns.visible_post_limit

    socket
    |> assign(:loading_more, false)
    |> assign(:no_more_posts, no_more_posts)
  end

  defp maybe_group_reply_chains(posts, socket) when is_list(posts) do
    if socket.assigns.filter in [nil, "for_you", "timeline"] do
      group_reply_chains(posts)
    else
      posts
    end
  end

  defp maybe_group_reply_chains(posts, _socket), do: posts

  defp group_reply_chains(posts) when is_list(posts) do
    ids_in_feed = MapSet.new(Enum.map(posts, & &1.id))

    local_parent_ids =
      posts
      |> Enum.map(&Map.get(&1, :reply_to_id))
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    remote_parent_refs =
      posts
      |> Enum.map(&normalized_in_reply_to/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    thread_keys_by_id =
      posts
      |> Enum.reduce(%{}, fn post, acc ->
        Map.put(
          acc,
          post.id,
          thread_group_key(post, ids_in_feed, local_parent_ids, remote_parent_refs)
        )
      end)

    posts
    |> Enum.group_by(fn post -> Map.get(thread_keys_by_id, post.id, {:post, post.id}) end)
    |> Enum.map(fn {_group_key, grouped_posts} -> choose_thread_representative(grouped_posts) end)
    |> Enum.sort_by(&timeline_sort_key/1, :desc)
  end

  defp group_reply_chains(posts), do: posts

  defp choose_thread_representative([post]), do: post

  defp choose_thread_representative(grouped_posts) do
    Enum.max_by(grouped_posts, &timeline_sort_key/1, fn -> List.first(grouped_posts) end)
  end

  defp timeline_sort_key(post) do
    {Map.get(post, :inserted_at), Map.get(post, :id, 0)}
  end

  defp thread_group_key(post, ids_in_feed, local_parent_ids, remote_parent_refs) do
    cond do
      is_integer(Map.get(post, :reply_to_id)) and MapSet.member?(ids_in_feed, post.reply_to_id) ->
        {:local_thread, post.reply_to_id}

      is_binary(normalized_in_reply_to(post)) ->
        {:remote_thread, normalized_in_reply_to(post)}

      MapSet.member?(local_parent_ids, post.id) ->
        {:local_thread, post.id}

      matched_ref = Enum.find(thread_self_refs(post), &MapSet.member?(remote_parent_refs, &1)) ->
        {:remote_thread, matched_ref}

      true ->
        {:post, post.id}
    end
  end

  defp thread_self_refs(post) do
    [Map.get(post, :activitypub_id), Map.get(post, :activitypub_url)]
    |> Enum.map(&normalize_thread_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalized_in_reply_to(post) do
    post
    |> Map.get(:media_metadata, %{})
    |> get_in(["inReplyTo"])
    |> normalize_thread_ref()
  end

  defp normalize_thread_ref(value) when is_binary(value) do
    value = String.trim(value)
    Elektrine.Strings.present(value)
  end

  defp normalize_thread_ref(_), do: nil

  defp load_feed_data(socket, limit) do
    user = socket.assigns.current_user
    session_context = socket.assigns[:session_context] || %{}

    personalized_result =
      load_with_timeout(
        :for_you_feed,
        fn ->
          Integrations.overview_for_you_feed(
            user.id,
            limit: limit,
            session_context: session_context
          )
          |> build_feed_state(user.id)
        end,
        @feed_load_timeout_ms
      )

    case personalized_result do
      {:ok, feed_data} ->
        assign_feed_data(socket, feed_data)

      {:error, _reason} ->
        fallback_result =
          load_with_timeout(
            :public_feed_fallback,
            fn ->
              Integrations.overview_public_timeline(
                user_id: user.id,
                limit: limit
              )
              |> build_feed_state(user.id)
            end,
            5000
          )

        case fallback_result do
          {:ok, feed_data} ->
            socket
            |> assign_feed_data(feed_data)
            |> put_flash(:info, "Showing recent posts while personalized ranking catches up.")

          {:error, _fallback_reason} ->
            socket
            |> assign(:all_posts, [])
            |> assign(:filtered_all_posts, [])
            |> assign(:user_likes, %{})
            |> assign(:user_boosts, %{})
            |> assign(:user_saves, %{})
            |> assign(:user_follows, %{})
            |> assign(:pending_follows, %{})
            |> assign(:post_reactions, %{})
            |> assign(:loading_feed, false)
            |> assign(:loading_more, false)
            |> assign(:no_more_posts, true)
            |> assign(:data_loaded, true)
            |> put_flash(:error, "Feed took too long to load. Please refresh to try again.")
        end
    end
  end

  defp cap_overview_posts(posts) when is_list(posts) do
    Enum.take(posts, @overview_feed_limit)
  end

  defp cap_overview_posts(_posts), do: []

  defp prepend_and_cap_overview_posts(posts, post) when is_list(posts) do
    updated_posts = [post | Enum.reject(posts, &(&1.id == post.id))]
    cap_overview_posts(updated_posts)
  end

  defp build_feed_state(all_posts, user_id) do
    all_posts = cap_overview_posts(all_posts)
    user_likes = get_user_likes_map(user_id, all_posts)
    user_boosts = get_user_boosts_map(user_id, all_posts)
    user_saves = get_user_saves(user_id, all_posts)
    user_follows = get_user_follows(user_id, all_posts)
    pending_follows = get_pending_follows(user_id, all_posts)
    post_reactions = get_post_reactions(all_posts)

    %{
      all_posts: all_posts,
      user_likes: user_likes,
      user_boosts: user_boosts,
      user_saves: user_saves,
      user_follows: user_follows,
      pending_follows: pending_follows,
      post_reactions: post_reactions
    }
  end

  defp register_post_state(socket, %{id: message_id}) when is_integer(message_id) do
    socket
    |> update(:user_likes, &Map.put_new(&1, message_id, false))
    |> update(:user_boosts, &Map.put_new(&1, message_id, false))
    |> update(:user_saves, &Map.put_new(&1, message_id, false))
    |> update(:post_reactions, &Map.put_new(&1, message_id, []))
  end

  defp register_post_state(socket, _post), do: socket

  defp default_session_context do
    %{
      liked_hashtags: [],
      liked_creators: [],
      liked_local_creators: [],
      liked_remote_creators: [],
      viewed_posts: [],
      dismissed_posts: [],
      total_views: 0,
      total_interactions: 0,
      engagement_rate: 0.0
    }
  end

  defp note_positive_signal(socket, nil), do: socket

  defp note_positive_signal(socket, post) do
    session_context =
      socket.assigns[:session_context]
      |> default_if_nil(default_session_context())
      |> merge_positive_signal(post, 1)

    assign(socket, :session_context, session_context)
  end

  defp note_view_signal(socket, post_id, _dwell_time_ms) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      session_context =
        socket.assigns[:session_context]
        |> default_if_nil(default_session_context())
        |> merge_view_signal(normalized_post_id)

      assign(socket, :session_context, session_context)
    end
  end

  defp maybe_note_dwell_interest(socket, post_id, dwell_time_ms) do
    if coerce_int(dwell_time_ms, 0) >= @session_interest_dwell_ms do
      note_positive_signal(socket, find_overview_post(socket.assigns.all_posts, post_id))
    else
      socket
    end
  end

  defp note_dismissal_signal(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      session_context =
        socket.assigns[:session_context]
        |> default_if_nil(default_session_context())
        |> Map.update!(:dismissed_posts, &merge_recent_unique(&1, [normalized_post_id], 50))

      assign(socket, :session_context, session_context)
    end
  end

  defp merge_positive_signal(session_context, post, interaction_increment) do
    hashtags =
      case Map.get(post, :hashtags) do
        hashtags when is_list(hashtags) -> Enum.map(hashtags, & &1.normalized_name)
        _ -> []
      end

    session_context
    |> Map.update!(:liked_hashtags, &merge_recent_unique(&1, hashtags, 20))
    |> Map.update!(:liked_local_creators, fn creators ->
      if post.federated do
        creators
      else
        merge_recent_unique(creators, [post.sender_id], 10)
      end
    end)
    |> Map.update!(:liked_remote_creators, fn creators ->
      if post.federated do
        merge_recent_unique(creators, [post.remote_actor_id], 10)
      else
        creators
      end
    end)
    |> then(fn context ->
      Map.put(context, :liked_creators, context.liked_local_creators)
    end)
    |> Map.update!(:total_interactions, &(&1 + interaction_increment))
    |> refresh_engagement_rate()
  end

  defp merge_view_signal(session_context, post_id) do
    already_viewed = post_id in (session_context.viewed_posts || [])

    session_context
    |> Map.update!(:viewed_posts, &merge_recent_unique(&1, [post_id], 50))
    |> Map.update!(:total_views, fn count -> if(already_viewed, do: count, else: count + 1) end)
    |> refresh_engagement_rate()
  end

  defp refresh_engagement_rate(session_context) do
    total_views =
      max(session_context.total_views || length(session_context.viewed_posts || []), 1)

    total_interactions = session_context.total_interactions || 0
    Map.put(session_context, :engagement_rate, total_interactions / total_views)
  end

  defp schedule_feed_rerank(socket, delay_ms) do
    if is_reference(socket.assigns[:feed_rerank_ref]) do
      Process.cancel_timer(socket.assigns.feed_rerank_ref)
    end

    assign(socket, :feed_rerank_ref, Process.send_after(self(), :refresh_feed_ranking, delay_ms))
  end

  defp remove_overview_post(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      socket
      |> update(:all_posts, fn posts ->
        Enum.reject(posts || [], &(&1.id == normalized_post_id))
      end)
      |> update(:filtered_all_posts, fn posts ->
        Enum.reject(posts || [], &(&1.id == normalized_post_id))
      end)
      |> update(:user_likes, &Map.delete(&1, normalized_post_id))
      |> update(:user_boosts, &Map.delete(&1, normalized_post_id))
      |> update(:user_saves, &Map.delete(&1, normalized_post_id))
      |> update(:post_reactions, &Map.delete(&1, normalized_post_id))
      |> maybe_clear_modal_post(normalized_post_id)
      |> sync_overview_posts_stream()
    end
  end

  defp maybe_clear_modal_post(socket, post_id) do
    case socket.assigns[:modal_post] do
      %{id: ^post_id} ->
        socket
        |> assign(:modal_post, nil)
        |> assign(:show_image_modal, false)
        |> assign(:modal_image_url, nil)
        |> assign(:modal_images, [])
        |> assign(:modal_image_index, 0)

      _ ->
        socket
    end
  end

  defp find_overview_post(posts, post_id) do
    normalized_post_id = normalize_post_id(post_id)
    Enum.find(posts || [], &(&1.id == normalized_post_id))
  end

  defp normalize_post_id(post_id) do
    case parse_positive_int(post_id) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp coerce_int(value, _default) when is_integer(value), do: value

  defp coerce_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp coerce_int(_, default), do: default

  defp coerce_float(value, _default) when is_float(value), do: value
  defp coerce_float(value, _default) when is_integer(value), do: value / 1

  defp coerce_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> default
    end
  end

  defp coerce_float(_, default), do: default

  defp merge_recent_unique(values, additions, limit) do
    Enum.reduce(List.wrap(additions), values || [], fn value, acc ->
      if is_nil(value) or (is_binary(value) and not Elektrine.Strings.present?(value)) do
        acc
      else
        (Enum.reject(acc, &(&1 == value)) ++ [value])
        |> trim_recent(limit)
      end
    end)
  end

  defp trim_recent(values, limit) when is_list(values) and length(values) > limit do
    Enum.take(values, -limit)
  end

  defp trim_recent(values, _limit), do: values

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp close_quote_modal(socket) do
    socket
    |> assign(:show_quote_modal, false)
    |> assign(:quote_target_post, nil)
    |> assign(:quote_content, "")
  end

  defp increment_overview_quote_count(socket, message_id) do
    update_overview_post(socket, message_id, fn post ->
      Map.put(post, :quote_count, (post.quote_count || 0) + 1)
    end)
  end

  defp update_overview_post(socket, message_id, updater) when is_function(updater, 1) do
    update_fn = fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id, do: updater.(post), else: post
      end)
    end

    updated_modal_post =
      case socket.assigns[:modal_post] do
        %{id: ^message_id} = post -> updater.(post)
        post -> post
      end

    socket
    |> update(:all_posts, update_fn)
    |> update(:filtered_all_posts, update_fn)
    |> assign(:modal_post, updated_modal_post)
    |> sync_overview_posts_stream()
  end

  defp reload_overview_post(message_id) when is_integer(message_id) do
    import Ecto.Query

    from(m in Elektrine.Messaging.Message,
      where: m.id == ^message_id,
      preload: ^MessagingMessages.timeline_post_preloads()
    )
    |> Repo.one()
    |> case do
      nil -> nil
      message -> Elektrine.Messaging.Message.decrypt_content(message)
    end
  end

  defp reload_overview_post(_), do: nil

  defp default_platform_stats do
    %{posts_today: 0, posts_this_week: 0, active_users: 0, top_post_today: nil, top_creators: []}
  end

  defp default_personal_stats do
    %{
      total_posts: 0,
      timeline_posts: 0,
      gallery_posts: 0,
      discussion_posts: 0,
      total_likes: 0,
      followers: 0,
      following: 0,
      top_post: nil
    }
  end

  defp load_with_timeout(key, loader, timeout_ms) when is_function(loader, 0) do
    task = Task.async(loader)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          Logger.warning("Overview loader exited (#{key}): #{inspect(reason)}")
          {:error, reason}

        nil ->
          Logger.warning("Overview loader timed out (#{key}) after #{timeout_ms}ms")
          {:error, :timeout}
      end
    catch
      :exit, reason ->
        Logger.warning("Overview loader crashed (#{key}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_platform_stats do
    import Ecto.Query
    today_start = NaiveDateTime.utc_now() |> NaiveDateTime.beginning_of_day()

    posts_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    week_start = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 24 * 60 * 60)

    posts_this_week =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    active_users =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: m.sender_id,
        distinct: true
      )
      |> Elektrine.Repo.all()
      |> length()

    top_post_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            m.visibility == "public" and is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.one()

    top_creators =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        group_by: m.sender_id,
        order_by: [desc: count(m.id)],
        limit: 5,
        select: m.sender_id
      )
      |> Elektrine.Repo.all()
      |> Enum.map(&Elektrine.Repo.get(Elektrine.Accounts.User, &1))
      |> Enum.reject(&is_nil/1)
      |> Elektrine.Repo.preload(:profile)

    %{
      posts_today: posts_today,
      posts_this_week: posts_this_week,
      active_users: active_users,
      top_post_today: top_post_today,
      top_creators: top_creators
    }
  end

  defp get_personal_stats(user_id) do
    import Ecto.Query

    total_posts =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    timeline_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "post" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    gallery_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    discussion_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "discussion" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    total_likes =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: sum(m.like_count)
      )
      |> Elektrine.Repo.one() || 0

    followers = Elektrine.Profiles.get_follower_count(user_id)
    following = Elektrine.Profiles.get_following_count(user_id)

    top_post =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        select: %{id: m.id, title: m.title, likes: m.like_count, type: m.post_type}
      )
      |> Elektrine.Repo.one()

    %{
      total_posts: total_posts,
      timeline_posts: timeline_posts,
      gallery_posts: gallery_posts,
      discussion_posts: discussion_posts,
      total_likes: total_likes,
      followers: followers,
      following: following,
      top_post: top_post
    }
  end

  defp get_user_own_posts(user_id) do
    import Ecto.Query

    from(m in Messaging.Message,
      where:
        m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: @overview_feed_limit,
      preload: [sender: [:profile], conversation: [], link_preview: [], hashtags: []]
    )
    |> Elektrine.Repo.all()
  end

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
