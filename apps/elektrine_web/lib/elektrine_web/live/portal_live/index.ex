defmodule ElektrineWeb.PortalLive.Index do
  use ElektrineWeb, :live_view
  require Logger
  alias Elektrine.ActivityPub.{LemmyCache, RefreshCountsWorker}
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Reactions
  alias Elektrine.Notifications
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Security.SafeExternalURL
  alias Elektrine.Social.Messages, as: MessagingMessages
  alias ElektrineWeb.Components.Social.PostUtilities
  alias ElektrineWeb.Live.PostInteractions
  alias ElektrineWeb.Platform.Integrations
  alias ElektrineWeb.PortalLive.ActivityInspector
  alias ElektrineWeb.PortalLive.Attention
  alias ElektrineWeb.PortalLive.DashboardData
  alias ElektrineWeb.PortalLive.RecentActivity
  alias ElektrineWeb.PortalLive.SessionContext
  import ElektrineWeb.Components.Platform.ENav
  import ElektrineWeb.Live.Helpers.PostStateHelpers
  @default_filter "all"
  @allowed_filters ~w(all my_posts timeline gallery discussions)
  @shared_feed_filters ~w(all)
  @default_attention_filter "all"
  @allowed_attention_filters ~w(all email chat requests social system)
  @feed_load_timeout_ms 12_000
  @stats_load_timeout_ms 8000
  @dashboard_load_timeout_ms 10_000
  @portal_feed_limit 20
  @portal_feed_step 20
  @portal_count_refresh_limit 20
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    if user do
      locale = session["locale"] || user.locale || "en"
      Gettext.put_locale(ElektrineWeb.Gettext, locale)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "gallery:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")

        if Elektrine.RuntimeEnv.environment() != :test do
          send(self(), :load_feed_data)
        end

        send(self(), :load_stats_data)
        send(self(), :load_dashboard_data)
      end

      timezone = user.timezone || "Etc/UTC"
      time_format = user.time_format || "12"
      cached_dashboard = Elektrine.AppCache.get_portal_dashboard(user.id)
      cached_platform_stats = Elektrine.AppCache.get_user_stats(:portal_platform_stats, :global)
      cached_personal_stats = Elektrine.AppCache.get_user_stats(:portal_personal_stats, user.id)

      socket =
        socket
        |> assign(:page_title, "Portal")
        |> assign(:all_posts, [])
        |> assign(:filtered_all_posts, [])
        |> assign(:user_likes, %{})
        |> assign(:user_downvotes, %{})
        |> assign(:user_boosts, %{})
        |> assign(:user_saves, %{})
        |> assign(:lemmy_counts, %{})
        |> assign(:post_interactions, %{})
        |> assign(:user_follows, %{})
        |> assign(:pending_follows, %{})
        |> assign(:remote_follow_overrides, %{})
        |> assign(:post_reactions, %{})
        |> assign(:post_replies, %{})
        |> assign(:remote_reply_errors, %{})
        |> assign(:filter, @default_filter)
        |> assign(:attention_filter, @default_attention_filter)
        |> assign(:platform_stats, cached_platform_stats || default_platform_stats())
        |> assign(:personal_stats, cached_personal_stats || default_personal_stats())
        |> assign(:timezone, timezone)
        |> assign(:time_format, time_format)
        |> assign(:loading_feed, true)
        |> assign(:loading_stats, is_nil(cached_platform_stats) or is_nil(cached_personal_stats))
        |> assign(:loading_dashboard, is_nil(cached_dashboard))
        |> assign(:portal_credits, atomine_credit_balance(user.id))
        |> assign(:dashboard, cached_dashboard || DashboardData.default())
        |> assign(:portal_view, "feed")
        |> assign(:reader_params, %{})
        |> assign(:dashboard_last_refreshed_at, nil)
        |> assign(:data_loaded, false)
        |> assign(:feed_posts_cache, %{})
        |> assign(:feed_source, feed_source_key(@default_filter))
        |> assign(:visible_post_limit, @portal_feed_limit)
        |> assign(:loading_more, false)
        |> assign(:no_more_posts, false)
        |> assign(:last_fetched_post_count, 0)
        |> assign(:session_context, SessionContext.default())
        |> assign(:show_image_modal, false)
        |> assign(:modal_image_url, nil)
        |> assign(:modal_images, [])
        |> assign(:modal_image_index, 0)
        |> assign(:modal_post, nil)
        |> assign(:show_quote_modal, false)
        |> assign(:quote_target_post, nil)
        |> assign(:quote_content, "")
        |> assign(:show_activity_inspector, false)
        |> assign(:activity_inspector, ActivityInspector.default())
        |> assign(:loading_remote_replies, MapSet.new())

      socket =
        if connected?(socket) and Elektrine.RuntimeEnv.environment() == :test do
          load_feed_data(socket, @portal_feed_limit)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please sign in to view your personalized portal")
       |> push_navigate(to: Elektrine.Paths.login_path())}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous_filter = socket.assigns[:filter] || @default_filter
    filter = normalize_filter(params["filter"])
    attention_filter = normalize_attention_filter(params["attention"])

    reader_params = Map.take(params, ["rss_source", "rss_density", "rss_item"])

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:attention_filter, attention_filter)
      |> assign(:portal_view, normalize_portal_view(params))
      |> assign(:reader_params, reader_params)

    socket =
      maybe_switch_portal_filter(socket, previous_filter, filter)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = normalize_filter(filter)

    {:noreply,
     push_patch(
       socket,
       to: ~p"/portal?#{[filter: filter, attention: socket.assigns.attention_filter]}"
     )}
  end

  def handle_event("set_attention_filter", %{"filter" => filter}, socket) do
    filter = normalize_attention_filter(filter)

    {:noreply,
     push_patch(socket, to: ~p"/portal?#{[filter: socket.assigns.filter, attention: filter]}")}
  end

  def handle_event("show_following", _params, socket) do
    handle_event("inspect_activity", %{"section" => "following"}, socket)
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_activity_inspector, false)
     |> assign(:activity_inspector, ActivityInspector.default())}
  end

  def handle_event("inspect_activity", %{"section" => section}, socket) do
    current_user = socket.assigns.current_user
    inspector = ActivityInspector.build(current_user.id, section, socket.assigns.personal_stats)

    {:noreply,
     socket
     |> assign(:show_activity_inspector, true)
     |> assign(:activity_inspector, inspector)}
  end

  def handle_event("load_more_activity", _params, socket) do
    inspector = socket.assigns.activity_inspector

    if socket.assigns.loading_stats or inspector.no_more or is_nil(inspector.section) do
      {:noreply, socket}
    else
      next_entries =
        ActivityInspector.list_entries(
          socket.assigns.current_user.id,
          inspector.section,
          offset: inspector.offset,
          limit: ActivityInspector.page_size(),
          query: inspector.query
        )

      updated_inspector = %{
        inspector
        | entries: inspector.entries ++ next_entries,
          offset: inspector.offset + length(next_entries),
          no_more: length(next_entries) < ActivityInspector.page_size()
      }

      {:noreply, assign(socket, :activity_inspector, updated_inspector)}
    end
  end

  def handle_event("search_activity", %{"query" => query}, socket) do
    inspector = socket.assigns.activity_inspector
    query = String.trim(query || "")

    if is_nil(inspector.section) do
      {:noreply, socket}
    else
      entries =
        ActivityInspector.list_entries(
          socket.assigns.current_user.id,
          inspector.section,
          offset: 0,
          limit: ActivityInspector.page_size(),
          query: query
        )

      updated_inspector = %{
        inspector
        | query: query,
          entries: entries,
          offset: length(entries),
          no_more: length(entries) < ActivityInspector.page_size()
      }

      {:noreply, assign(socket, :activity_inspector, updated_inspector)}
    end
  end

  def handle_event("clear_activity_search", _params, socket) do
    handle_event("search_activity", %{"query" => ""}, socket)
  end

  def handle_event("unfollow_remote", %{"remote-actor-id" => remote_actor_id}, socket) do
    current_user = socket.assigns.current_user

    case Integer.parse(remote_actor_id) do
      {actor_id, ""} ->
        case Profiles.unfollow_remote_actor(current_user.id, actor_id) do
          {:ok, :unfollowed} ->
            {:noreply,
             socket
             |> refresh_portal_following_state(current_user.id)
             |> put_flash(:info, "Unfollowed remote user")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to unfollow")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid user id")}
    end
  end

  def handle_event("unfollow_local", %{"followed-id" => followed_id}, socket) do
    current_user = socket.assigns.current_user

    case Integer.parse(followed_id) do
      {user_id, ""} ->
        Profiles.unfollow_user(current_user.id, user_id)

        {:noreply,
         socket
         |> refresh_portal_following_state(current_user.id)
         |> put_flash(:info, "Unfollowed user")}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid user id")}
    end
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.loading_feed or socket.assigns.loading_more or socket.assigns.no_more_posts do
      {:noreply, socket}
    else
      next_limit = socket.assigns.visible_post_limit + @portal_feed_step

      {:noreply,
       socket
       |> assign(:loading_more, true)
       |> assign(:visible_post_limit, next_limit)
       |> maybe_load_feed_data(next_limit)}
    end
  end

  def handle_event("load_remote_replies", %{"post_id" => post_id}, socket) do
    case parse_positive_int(post_id) do
      {:ok, post_id} ->
        loading_set = socket.assigns.loading_remote_replies

        if MapSet.member?(loading_set, post_id) do
          {:noreply, socket}
        else
          user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

          loading_set = MapSet.put(loading_set, post_id)
          remote_reply_errors = Map.delete(socket.assigns.remote_reply_errors, post_id)

          {post_replies, remote_reply_errors} =
            case fetch_portal_remote_replies(post_id, user_id) do
              {:ok, replies} when replies != [] ->
                {Map.put(socket.assigns.post_replies, post_id, replies), remote_reply_errors}

              {:ok, []} ->
                {socket.assigns.post_replies,
                 Map.put(remote_reply_errors, post_id, "Could not load replies.")}

              {:error, _reason} ->
                {socket.assigns.post_replies,
                 Map.put(remote_reply_errors, post_id, "Could not load replies.")}
            end

          {:noreply,
           socket
           |> assign(:loading_remote_replies, loading_set)
           |> assign(:post_replies, post_replies)
           |> assign(:remote_reply_errors, remote_reply_errors)
           |> assign(:loading_remote_replies, MapSet.delete(loading_set, post_id))
           |> sync_portal_posts_stream()}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid post id")}
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          post = find_portal_post(socket.assigns.all_posts, message_id)

          if post && PostUtilities.community_post?(post) do
            {:noreply, apply_portal_like_interaction(socket, post, message_id, :like)}
          else
            user_id = socket.assigns.current_user.id
            currently_liked = Map.get(socket.assigns.user_likes, message_id, false)

            if currently_liked do
              {:noreply, socket}
            else
              case Integrations.social_like_post(user_id, message_id) do
                {:ok, _} ->
                  update_likes_fn = update_portal_post_count_fn(message_id, :like_count, 1)

                  {:noreply,
                   socket
                   |> update(:user_likes, &Map.put(&1, message_id, true))
                   |> put_portal_like_interaction(post, message_id, true)
                   |> update(:all_posts, update_likes_fn)
                   |> update(:filtered_all_posts, update_likes_fn)
                   |> sync_portal_posts_stream()
                   |> SessionContext.note_positive(post)}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to like post")}
              end
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
    case parse_positive_int(post_id) do
      {:ok, message_id} ->
        if Map.get(socket.assigns.user_likes || %{}, message_id, false) do
          handle_event("unlike_post", %{"message_id" => post_id}, socket)
        else
          handle_event("like_post", %{"message_id" => post_id}, socket)
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid post id")}
    end
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    handle_event("unlike_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          post = find_portal_post(socket.assigns.all_posts, message_id)

          if post && PostUtilities.community_post?(post) do
            {:noreply, apply_portal_like_interaction(socket, post, message_id, :unlike)}
          else
            if Map.get(socket.assigns.user_likes, message_id, false) do
              case Integrations.social_unlike_post(socket.assigns.current_user.id, message_id) do
                {:ok, _} ->
                  update_likes_fn = update_portal_post_count_fn(message_id, :like_count, -1)

                  {:noreply,
                   socket
                   |> update(:user_likes, &Map.put(&1, message_id, false))
                   |> put_portal_like_interaction(post, message_id, false)
                   |> update(:all_posts, update_likes_fn)
                   |> update(:filtered_all_posts, update_likes_fn)
                   |> sync_portal_posts_stream()}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to unlike post")}
              end
            else
              {:noreply, socket}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    handle_event("downvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("downvote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case find_portal_post(socket.assigns.all_posts, message_id) do
            nil ->
              {:noreply, put_flash(socket, :error, "Invalid post id")}

            post ->
              {:noreply, apply_portal_downvote_interaction(socket, post, message_id, :downvote)}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    end
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    handle_event("undownvote_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("undownvote_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case find_portal_post(socket.assigns.all_posts, message_id) do
            nil ->
              {:noreply, put_flash(socket, :error, "Invalid post id")}

            post ->
              {:noreply, apply_portal_downvote_interaction(socket, post, message_id, :undownvote)}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id
          currently_boosted = Map.get(socket.assigns.user_boosts, message_id, false)
          post = find_portal_post(socket.assigns.all_posts, message_id)

          if currently_boosted do
            {:noreply, socket}
          else
            case Integrations.social_boost_post(user_id, message_id) do
              {:ok, _} ->
                update_boosts_fn = update_portal_post_count_fn(message_id, :share_count, 1)

                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, true))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)
                 |> sync_portal_posts_stream()
                 |> SessionContext.note_positive(post)}

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

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    handle_event("boost_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    handle_event("unboost_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          if Map.get(socket.assigns.user_boosts, message_id, false) do
            case Integrations.social_unboost_post(socket.assigns.current_user.id, message_id) do
              {:ok, _} ->
                update_boosts_fn = update_portal_post_count_fn(message_id, :share_count, -1)

                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, false))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)
                 |> sync_portal_posts_stream()}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unboost post")}
            end
          else
            {:noreply, socket}
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          if Map.get(socket.assigns.user_saves, message_id, false) do
            {:noreply, socket}
          else
            case Integrations.social_save_post(socket.assigns.current_user.id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_saves, &Map.put(&1, message_id, true))
                 |> sync_portal_posts_stream()
                 |> put_flash(:info, "Saved")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to save")}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          if Map.get(socket.assigns.user_saves, message_id, false) do
            case Integrations.social_unsave_post(socket.assigns.current_user.id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_saves, &Map.put(&1, message_id, false))
                 |> sync_portal_posts_stream()
                 |> put_flash(:info, "Removed from saved")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unsave")}
            end
          else
            {:noreply, socket}
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
            Repo.get_by(Elektrine.Social.MessageReaction,
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
                 |> sync_portal_posts_stream()}

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
                 |> sync_portal_posts_stream()}

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
            reloaded_quote = reload_portal_post(quote_post.id) || quote_post

            {:noreply,
             socket
             |> increment_portal_quote_count(quote_target.id)
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
            {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post))}

          post_type == "post" ->
            {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post_id))}

          post_type == "gallery" ->
            path =
              if post && post.activitypub_id do
                Elektrine.Paths.post_path(post)
              else
                Elektrine.Paths.post_path(post_id)
              end

            {:noreply, push_navigate(socket, to: path)}

          post_type == "discussion" && post ->
            conversation =
              if Ecto.assoc_loaded?(post.conversation) do
                post.conversation
              else
                Elektrine.Repo.get(Elektrine.Social.Conversation, post.conversation_id)
              end

            if conversation do
              {:noreply,
               push_navigate(socket, to: ~p"/communities/#{conversation.name}/post/#{post_id}")}
            else
              {:noreply, socket}
            end

          true ->
            {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post_id))}
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
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, url)}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} ->
        {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post_id))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_remote_post", %{"id" => id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    path =
      case parse_positive_int(id) do
        {:ok, post_id} -> Elektrine.Paths.remote_post_path(post_id)
        :error -> Elektrine.Paths.post_path_or_external(url)
      end

    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, path)}
  end

  def handle_event("navigate_to_remote_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, url)}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} ->
        {:noreply, push_navigate(socket, to: Elektrine.Paths.remote_post_path(post_id))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post && post.federated && post.activitypub_id do
          {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post))}
        else
          {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(message_id))}
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
                  Elektrine.Paths.post_path(post)
                else
                  Elektrine.Paths.post_path(message_id)
                end

              _ ->
                Elektrine.Paths.post_path(message_id)
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
                  Elektrine.Paths.post_path(post)
                else
                  Elektrine.Paths.post_path(message_id)
                end

              _ ->
                Elektrine.Paths.post_path(message_id)
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
              case Messaging.delete_message(message_id, user.id) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> update(:all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> update(:filtered_all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> sync_portal_posts_stream()
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
    {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(message_id))}
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
               |> sync_portal_posts_stream()}

            {:ok, :not_following} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:local, user_id}, false))
               |> sync_portal_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unfollow user")}
          end
        else
          case Integrations.social_follow_user(current_user.id, user_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:local, user_id}, true))
               |> sync_portal_posts_stream()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to follow user")}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_follow_remote", params, socket) do
    remote_actor_id = params["remote_actor_id"] || params["actor_id"]

    case parse_positive_int(remote_actor_id) do
      {:ok, actor_id} ->
        current_user = socket.assigns.current_user
        is_following = Map.get(socket.assigns.user_follows, {:remote, actor_id}, false)

        if is_following do
          case Elektrine.Profiles.unfollow_remote_actor(current_user.id, actor_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, false))
               |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, false))
               |> put_remote_follow_override(actor_id, :none)
               |> push_remote_follow_state(actor_id, :none)
               |> sync_portal_posts_stream()}

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
               |> put_remote_follow_override(actor_id, :following)
               |> push_remote_follow_state(actor_id, :following)
               |> sync_portal_posts_stream()}

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
        Integrations.portal_record_dismissal(user.id, post_id, "not_interested", nil)

        socket
        |> SessionContext.note_dismissal(post_id)
        |> remove_portal_post(post_id)
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
        Integrations.portal_record_dismissal(user.id, post_id, "hidden", nil)

        socket
        |> SessionContext.note_dismissal(post_id)
        |> remove_portal_post(post_id)
        |> put_flash(:info, "Post hidden from your portal.")
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
            source: params["source"] || "portal"
          }

          Integrations.portal_record_view_with_dwell(user.id, post_id, attrs)

          socket
          |> SessionContext.note_view(post_id)
          |> SessionContext.maybe_note_dwell_interest(
            find_portal_post(socket.assigns.all_posts, post_id),
            params["dwell_time_ms"]
          )
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
              source: view["source"] || "portal"
            }

            Integrations.portal_record_view_with_dwell(user.id, post_id, attrs)

            acc
            |> SessionContext.note_view(post_id)
            |> SessionContext.maybe_note_dwell_interest(
              find_portal_post(acc.assigns.all_posts, post_id),
              view["dwell_time_ms"]
            )
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
          Integrations.portal_record_dismissal(user.id, post_id, type, dwell_time_ms)

          socket
          |> SessionContext.note_dismissal(post_id)
        else
          socket
        end
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("update_session_context", params, socket) do
    session_context = SessionContext.update_from_params(socket.assigns[:session_context], params)

    {:noreply, assign(socket, :session_context, session_context)}
  end

  def handle_event("", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp fetch_portal_remote_replies(post_id, user_id) do
    opts =
      if user_id do
        [user_id: user_id, limit_per_post: 20]
      else
        [limit_per_post: 20]
      end

    replies =
      [post_id]
      |> Integrations.social_direct_replies_for_posts(opts)
      |> Map.get(post_id, [])

    {:ok, replies}
  rescue
    reason -> {:error, reason}
  catch
    kind, reason -> {:error, {kind, reason}}
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
     |> sync_portal_posts_stream()}
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
     |> sync_portal_posts_stream()}
  end

  def handle_info(:load_dashboard_data, socket) do
    user = socket.assigns.current_user

    case load_with_timeout(
           :dashboard_data,
           fn -> build_dashboard_data(user) end,
           @dashboard_load_timeout_ms
         ) do
      {:ok, dashboard} ->
        Elektrine.AppCache.cache_portal_dashboard(user.id, dashboard)

        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:loading_dashboard, false)
         |> assign(:dashboard_last_refreshed_at, DateTime.utc_now())}

      {:error, _reason} ->
        # Keep the last-known (possibly cached) dashboard instead of zeroing it out.
        {:noreply, assign(socket, :loading_dashboard, false)}
    end
  end

  def handle_info(:load_feed_data, socket) do
    {:noreply, maybe_load_feed_data(socket, socket.assigns.visible_post_limit)}
  end

  def handle_info({:load_more_feed, limit}, socket) do
    {:noreply, maybe_load_feed_data(socket, limit)}
  end

  def handle_info({:portal_feed_data_result, ref, {:ok, result}}, socket) do
    if socket.assigns[:feed_load_ref] == ref do
      {:noreply, apply_feed_data_result(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:portal_feed_data_result, ref, {:exit, reason}}, socket) do
    Logger.warning("Portal feed async loader exited: #{inspect(reason)}")

    if socket.assigns[:feed_load_ref] == ref do
      {:noreply,
       socket
       |> assign(:loading_feed, false)
       |> assign(:loading_more, false)
       |> put_flash(:error, "Portal feed failed to load. Try refreshing.")}
    else
      {:noreply, socket}
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
        {:ok, stats} ->
          Elektrine.AppCache.cache_user_stats(:portal_platform_stats, :global, stats)
          stats

        {:error, _reason} ->
          socket.assigns.platform_stats || default_platform_stats()
      end

    personal_stats =
      case load_with_timeout(
             :personal_stats,
             fn -> get_personal_stats(user.id) end,
             @stats_load_timeout_ms
           ) do
        {:ok, stats} ->
          Elektrine.AppCache.cache_user_stats(:portal_personal_stats, user.id, stats)
          stats

        {:error, _reason} ->
          socket.assigns.personal_stats || default_personal_stats()
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

  defp get_user_downvotes_map(user_id, posts) do
    message_ids = Enum.map(posts, & &1.id)

    user_votes =
      case Integrations.social_get_user_votes(user_id, message_ids) do
        votes when is_map(votes) -> votes
        _ -> %{}
      end

    Map.new(message_ids, fn message_id ->
      {message_id, Map.get(user_votes, message_id) == "down"}
    end)
  end

  defp apply_portal_like_interaction(socket, post, message_id, direction)
       when direction in [:like, :unlike] do
    interaction_key = portal_post_interaction_key(post)

    current_state =
      Map.get(socket.assigns.post_interactions, interaction_key, %{
        liked: false,
        downvoted: false,
        like_delta: 0
      })

    currently_liked =
      Map.get(socket.assigns.user_likes, message_id, Map.get(current_state, :liked, false))

    next_liked = direction == :like

    if currently_liked == next_liked do
      socket
    else
      delta_change = if next_liked, do: 1, else: -1

      post_interactions =
        Map.put(socket.assigns.post_interactions, interaction_key, %{
          liked: next_liked,
          downvoted: false,
          like_delta: 0
        })

      update_likes_fn = fn posts ->
        Enum.map(posts, fn post_candidate ->
          if post_candidate.id == message_id do
            base_like_count = post_candidate.like_count || post_candidate.score || 0
            updated_like_count = max(base_like_count + delta_change, 0)

            post_candidate
            |> Map.put(:like_count, updated_like_count)
            |> Map.put(:score, updated_like_count)
          else
            post_candidate
          end
        end)
      end

      result =
        if next_liked do
          Integrations.social_like_post(socket.assigns.current_user.id, message_id)
        else
          Integrations.social_unlike_post(socket.assigns.current_user.id, message_id)
        end

      case result do
        {:ok, _} ->
          socket
          |> update(:user_likes, &Map.put(&1, message_id, next_liked))
          |> assign(:post_interactions, post_interactions)
          |> update(:all_posts, update_likes_fn)
          |> update(:filtered_all_posts, update_likes_fn)
          |> sync_portal_posts_stream()

        {:error, _} ->
          put_flash(
            socket,
            :error,
            if(next_liked, do: "Failed to like post", else: "Failed to unlike post")
          )
      end
    end
  end

  defp update_portal_post_count_fn(message_id, count_field, delta) do
    fn posts ->
      Enum.map(posts, fn post ->
        cond do
          post.id == message_id ->
            update_portal_post_count(post, count_field, delta)

          match?(%{id: ^message_id}, portal_shared_message(post)) ->
            Map.put(
              post,
              :shared_message,
              update_portal_post_count(portal_shared_message(post), count_field, delta)
            )

          true ->
            post
        end
      end)
    end
  end

  defp update_portal_post_count(post, count_field, delta) do
    current_count = Map.get(post, count_field, 0) || 0
    Map.put(post, count_field, max(current_count + delta, 0))
  end

  defp put_portal_like_interaction(socket, post, message_id, liked?) do
    interaction_key = portal_post_interaction_key(post || %{id: message_id})

    update(socket, :post_interactions, fn post_interactions ->
      Map.update(
        post_interactions,
        interaction_key,
        %{liked: liked?, downvoted: false, like_delta: 0},
        &(&1 |> Map.put(:liked, liked?) |> Map.put(:downvoted, false))
      )
    end)
  end

  defp apply_portal_downvote_interaction(socket, post, message_id, direction)
       when direction in [:downvote, :undownvote] do
    interaction_key = portal_post_interaction_key(post)

    current_state =
      Map.get(socket.assigns.post_interactions, interaction_key, %{
        liked: false,
        downvoted: false,
        like_delta: 0
      })

    currently_liked =
      Map.get(socket.assigns.user_likes, message_id, Map.get(current_state, :liked, false))

    currently_downvoted =
      Map.get(
        socket.assigns.user_downvotes,
        message_id,
        Map.get(current_state, :downvoted, false)
      )

    next_downvoted = direction == :downvote

    if currently_downvoted == next_downvoted do
      socket
    else
      score_delta =
        cond do
          next_downvoted && currently_liked -> -2
          next_downvoted -> -1
          true -> 1
        end

      update_posts_fn = fn posts ->
        Enum.map(posts, fn post_candidate ->
          if post_candidate.id == message_id do
            like_count = post_candidate.like_count || 0
            downvote_count = post_candidate.downvotes || post_candidate.dislike_count || 0

            updated_like_count =
              if next_downvoted && currently_liked, do: max(like_count - 1, 0), else: like_count

            updated_downvotes =
              if next_downvoted, do: downvote_count + 1, else: max(downvote_count - 1, 0)

            updated_upvotes =
              if next_downvoted && currently_liked,
                do: max((post_candidate.upvotes || like_count) - 1, 0),
                else: post_candidate.upvotes || like_count

            post_candidate
            |> Map.put(:score, (post_candidate.score || like_count) + score_delta)
            |> Map.put(:like_count, updated_like_count)
            |> Map.put(:upvotes, updated_upvotes)
            |> Map.put(:downvotes, updated_downvotes)
            |> Map.put(:dislike_count, updated_downvotes)
          else
            post_candidate
          end
        end)
      end

      result =
        Integrations.social_vote_on_message(socket.assigns.current_user.id, message_id, "down")

      case result do
        {:ok, _} ->
          post_interactions =
            Map.put(socket.assigns.post_interactions, interaction_key, %{
              liked: false,
              downvoted: next_downvoted,
              like_delta: 0
            })

          socket
          |> update(:user_likes, &Map.put(&1, message_id, false))
          |> update(:user_downvotes, &Map.put(&1, message_id, next_downvoted))
          |> assign(:post_interactions, post_interactions)
          |> update(:all_posts, update_posts_fn)
          |> update(:filtered_all_posts, update_posts_fn)
          |> sync_portal_posts_stream()

        {:error, _} ->
          put_flash(socket, :error, "Failed to vote")
      end
    end
  end

  defp refresh_portal_following_state(socket, user_id) do
    following_count = Profiles.get_following_count(user_id)

    socket
    |> update(:personal_stats, &Map.put(&1, :following, following_count))
    |> maybe_refresh_activity_inspector(user_id)
  end

  defp maybe_refresh_activity_inspector(socket, user_id) do
    inspector = socket.assigns[:activity_inspector] || ActivityInspector.default()

    if socket.assigns[:show_activity_inspector] and inspector.section == "following" do
      limit = max(inspector.offset, ActivityInspector.page_size())

      entries =
        ActivityInspector.list_entries(user_id, "following",
          offset: 0,
          limit: limit,
          query: inspector.query
        )

      updated_inspector = %{
        inspector
        | entries: entries,
          offset: length(entries),
          no_more: length(entries) < limit,
          stat_value: Profiles.get_following_count(user_id)
      }

      assign(socket, :activity_inspector, updated_inspector)
    else
      socket
    end
  end

  defp get_user_boosts_map(user_id, posts) do
    get_user_boosts(user_id, posts)
  end

  # Identity Credits live in the optional Atomine engine. Fetch defensively so the
  # portal still renders if Atomine is disabled or unmigrated; nil hides the card.
  defp atomine_credit_balance(user_id) do
    if Code.ensure_loaded?(Atomine.Credits) do
      try do
        Atomine.Credits.balance(user_id, "atomine_credit")
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  defp build_dashboard_data(user) do
    mailbox = Integrations.email_mailbox(user.id)

    {inbox_messages, inbox_unread_count, reply_later_count} =
      if mailbox do
        dashboard = Integrations.portal_email_dashboard(user.id)
        {dashboard.inbox_messages, dashboard.inbox_unread_count, dashboard.reply_later_count}
      else
        {[], 0, 0}
      end

    chat_unread_count = Messaging.get_unread_count(user.id)
    recent_conversations = Messaging.list_chat_conversations(user.id, limit: 3)
    notifications_unread_count = Notifications.get_visible_unread_count(user.id)
    recent_notifications = Notifications.list_notifications(user.id, filter: :unread, limit: 8)
    pending_friend_requests = Friends.list_pending_requests(user.id)
    pending_follow_requests = Profiles.get_pending_follow_requests(user.id)
    vpn_configs = Integrations.vpn_user_configs(user.id)

    recent_posts =
      if Elektrine.RuntimeEnv.environment() == :test,
        do: [],
        else: Integrations.portal_recent_posts(user.id, limit: 3)

    pending_friend_requests_count = length(pending_friend_requests)
    pending_follow_requests_count = length(pending_follow_requests)
    vpn_config_count = length(vpn_configs)

    tasks =
      DashboardData.tasks(
        inbox_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count,
        vpn_config_count
      )

    alerts =
      DashboardData.alerts(
        inbox_unread_count,
        notifications_unread_count,
        chat_unread_count,
        pending_follow_requests_count
      )

    attention_queue =
      Attention.queue(
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
      attention_counts: Attention.counts(attention_queue),
      quick_actions: DashboardData.quick_actions(user),
      recent_activity:
        RecentActivity.build(
          inbox_messages,
          recent_conversations,
          recent_posts,
          recent_notifications,
          vpn_configs
        )
    }
  end

  defdelegate filtered_attention_queue(queue, filter), to: Attention, as: :filtered_queue

  defp normalize_attention_filter(filter) when filter in @allowed_attention_filters, do: filter
  defp normalize_attention_filter(_filter), do: @default_attention_filter

  defdelegate attention_filter_label(filter), to: Attention, as: :filter_label
  defdelegate attention_source_badge_class(source), to: Attention, as: :source_badge_class

  defp filtered_posts(posts, "timeline", _assigns) do
    Enum.filter(posts, fn post ->
      !PostUtilities.gallery_post?(post) && !PostUtilities.community_post?(post)
    end)
  end

  defp filtered_posts(posts, "gallery", _assigns) do
    Enum.filter(posts, &PostUtilities.gallery_post?/1)
  end

  defp filtered_posts(posts, "discussions", _assigns) do
    Enum.filter(posts, &PostUtilities.community_post?/1)
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

  defp normalize_portal_view(%{"view" => "reader"}), do: "reader"
  defp normalize_portal_view(%{"filter" => "rss"}), do: "reader"

  defp normalize_portal_view(params) when is_map(params) do
    if Enum.any?(["rss_source", "rss_density", "rss_item"], &Map.has_key?(params, &1)) do
      "reader"
    else
      "feed"
    end
  end

  defp maybe_switch_portal_filter(socket, previous_filter, filter) do
    cond do
      not socket.assigns.data_loaded ->
        assign_portal_posts_for_current_filter(socket)

      filter == previous_filter ->
        assign_portal_posts_for_current_filter(socket)

      feed_source_key(filter) == socket.assigns[:feed_source] ->
        assign_portal_posts_for_current_filter(socket)

      cached_posts = get_cached_feed_posts(socket.assigns, filter) ->
        socket
        |> assign(:loading_feed, false)
        |> assign(:loading_more, false)
        |> assign_feed_data(%{
          build_feed_state(cached_posts, socket.assigns.current_user.id)
          | all_posts: cached_posts
        })

      true ->
        socket
        |> assign(:loading_feed, true)
        |> assign(:loading_more, false)
        |> maybe_load_feed_data(socket.assigns.visible_post_limit)
    end
  end

  defp feed_source_key(filter) when filter in @shared_feed_filters, do: "shared"
  defp feed_source_key("discussions"), do: "discussions"
  defp feed_source_key(filter) when is_binary(filter), do: filter

  defp get_cached_feed_posts(assigns, filter) do
    assigns[:feed_posts_cache]
    |> Map.get(feed_source_key(filter))
  end

  defp put_feed_posts_cache(socket, source_key, posts) do
    update(socket, :feed_posts_cache, &Map.put(&1 || %{}, source_key, posts))
  end

  defp portal_filter_pill_class(current_filter, filter) do
    [
      "btn btn-sm rounded-full whitespace-nowrap border border-base-300",
      if(current_filter == filter,
        do: "btn-primary",
        else: "btn-ghost"
      )
    ]
  end

  defp base_posts_for_filter(_filter, %{all_posts: posts}) do
    posts
  end

  defp prepend_new_post(socket, post) do
    socket =
      socket
      |> register_post_state(post)
      |> update(:all_posts, &prepend_portal_post(&1, post))

    if post_matches_current_filter?(post, socket.assigns) do
      socket
      |> update(:filtered_all_posts, &prepend_portal_post(&1, post))
      |> sync_portal_posts_stream()
    else
      socket
    end
  end

  defp post_matches_current_filter?(post, assigns) do
    case assigns.filter do
      "my_posts" ->
        current_user = assigns[:current_user]
        current_user && post.sender_id == current_user.id

      filter ->
        [post]
        |> filtered_posts(filter, assigns)
        |> Enum.any?()
    end
  end

  defp assign_feed_data(socket, feed_data) do
    visible_limit = socket.assigns[:visible_post_limit] || @portal_feed_limit
    fetched_posts = feed_data.all_posts || []
    loading_more? = socket.assigns[:loading_more] == true

    fetched_posts =
      if loading_more? do
        merge_portal_posts(socket.assigns[:all_posts] || [], fetched_posts)
      else
        Enum.take(fetched_posts, visible_limit)
      end

    fetched_post_count = length(fetched_posts)
    previous_count = socket.assigns[:last_fetched_post_count] || 0
    source_key = feed_source_key(socket.assigns.filter)

    no_more_posts =
      fetched_post_count < socket.assigns.visible_post_limit or
        (loading_more? and previous_count > 0 and fetched_post_count <= previous_count)

    socket
    |> put_feed_posts_cache(source_key, fetched_posts)
    |> assign(:all_posts, fetched_posts)
    |> assign(:feed_source, source_key)
    |> assign(:user_likes, feed_data.user_likes)
    |> assign(:user_downvotes, feed_data.user_downvotes)
    |> assign(:user_boosts, feed_data.user_boosts)
    |> assign(:user_saves, feed_data.user_saves)
    |> assign(:lemmy_counts, feed_data.lemmy_counts || %{})
    |> assign(:post_interactions, feed_data.post_interactions || %{})
    |> assign(:user_follows, feed_data.user_follows)
    |> assign(:pending_follows, feed_data.pending_follows)
    |> assign(:post_reactions, feed_data.post_reactions)
    |> assign(:loading_feed, false)
    |> assign(:no_more_posts, no_more_posts)
    |> assign(:last_fetched_post_count, fetched_post_count)
    |> assign(:data_loaded, true)
    |> assign_portal_posts_for_current_filter()
  end

  defp merge_portal_posts(existing_posts, fetched_posts) do
    fetched_by_id = Map.new(fetched_posts, &{&1.id, &1})

    existing_posts
    |> Enum.map(fn existing_post ->
      case Map.get(fetched_by_id, existing_post.id) do
        nil ->
          existing_post

        fetched_post ->
          Map.merge(fetched_post, existing_post, fn key, fetched_value, existing_value ->
            if key in [:upvotes, :downvotes, :score] do
              existing_value
            else
              fetched_value
            end
          end)
      end
    end)
    |> then(fn preserved_existing_posts ->
      existing_ids = MapSet.new(Enum.map(existing_posts, & &1.id))
      preserved_existing_posts ++ Enum.reject(fetched_posts, &MapSet.member?(existing_ids, &1.id))
    end)
  end

  defp assign_portal_posts_for_current_filter(socket) do
    base_posts = socket.assigns.filter |> base_posts_for_filter(socket.assigns)

    socket
    |> assign(:filtered_all_posts, base_posts)
    |> sync_portal_posts_stream()
    |> maybe_schedule_portal_count_refresh()
  end

  defp sync_portal_posts_stream(socket) do
    _filtered_posts_for_view =
      socket.assigns.filtered_all_posts
      |> filtered_posts(socket.assigns.filter, socket.assigns)
      |> maybe_group_reply_chains(socket)

    socket
    |> assign(:loading_more, false)
  end

  defp maybe_schedule_portal_count_refresh(socket) do
    visible_posts =
      socket.assigns[:filtered_all_posts]
      |> List.wrap()
      |> filtered_posts(socket.assigns[:filter], socket.assigns)
      |> Enum.take(socket.assigns[:visible_post_limit] || @portal_feed_limit)

    if connected?(socket) && !test_env?() do
      RefreshCountsWorker.schedule_visible_refreshes(visible_posts)
    end

    socket
  end

  @doc false
  def visible_remote_count_refresh_ids(posts, limit \\ @portal_count_refresh_limit) do
    RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: limit)
  end

  defp test_env? do
    Elektrine.RuntimeEnv.environment() == :test
  end

  defp load_feed_data(socket, limit) do
    user = socket.assigns.current_user
    session_context = socket.assigns[:session_context] || %{}
    filter = socket.assigns.filter || @default_filter
    source_key = feed_source_key(filter)

    apply_feed_data_result(
      socket,
      load_feed_data_result(user.id, filter, source_key, limit, session_context)
    )
  end

  defp maybe_load_feed_data(socket, limit) do
    if connected?(socket) and !test_env?() do
      start_feed_data_async(socket, limit)
    else
      load_feed_data(socket, limit)
    end
  end

  defp start_feed_data_async(socket, limit) do
    user = socket.assigns.current_user
    session_context = socket.assigns[:session_context] || %{}
    filter = socket.assigns.filter || @default_filter
    source_key = feed_source_key(filter)
    ref = System.unique_integer([:positive])
    parent = self()

    Task.start(fn ->
      try do
        result = load_feed_data_result(user.id, filter, source_key, limit, session_context)
        send(parent, {:portal_feed_data_result, ref, {:ok, result}})
      rescue
        exception ->
          send(parent, {:portal_feed_data_result, ref, {:exit, Exception.message(exception)}})
      catch
        kind, reason ->
          send(parent, {:portal_feed_data_result, ref, {:exit, {kind, reason}}})
      end
    end)

    socket
    |> assign(:feed_load_ref, ref)
  end

  defp load_feed_data_result(user_id, filter, source_key, limit, session_context) do
    personalized_result =
      load_with_timeout(
        {:for_you_feed, source_key},
        fn ->
          load_portal_feed_posts(user_id, filter, limit, session_context)
          |> build_feed_state(user_id)
        end,
        @feed_load_timeout_ms
      )

    case personalized_result do
      {:ok, feed_data} ->
        {:ok, feed_data}

      {:error, _reason} ->
        fallback_posts = fallback_feed_posts(user_id, filter, limit)

        {:fallback,
         %{
           build_feed_state(fallback_posts, user_id)
           | all_posts: fallback_posts
         }}
    end
  end

  defp apply_feed_data_result(socket, {:ok, feed_data}) do
    assign_feed_data(socket, feed_data)
  end

  defp apply_feed_data_result(socket, {:fallback, feed_data}) do
    socket
    |> assign_feed_data(feed_data)
    |> put_flash(:info, "Showing recent posts while personalized ranking catches up.")
  end

  defp fallback_feed_posts(user_id, "timeline", limit) do
    Integrations.portal_public_timeline(user_id: user_id, limit: max(limit * 4, limit + 20))
    |> filtered_posts("timeline", %{})
    |> Enum.take(limit)
  end

  defp fallback_feed_posts(user_id, "gallery", limit) do
    Integrations.portal_public_timeline(user_id: user_id, limit: max(limit * 4, limit + 20))
    |> filtered_posts("gallery", %{})
    |> Enum.take(limit)
  end

  defp fallback_feed_posts(user_id, "discussions", limit) do
    Integrations.portal_public_community_posts(user_id: user_id, limit: limit)
  end

  defp fallback_feed_posts(user_id, "my_posts", limit) do
    get_user_own_posts(user_id, limit)
  end

  defp fallback_feed_posts(user_id, _filter, limit) do
    Integrations.portal_public_timeline(user_id: user_id, limit: limit)
  end

  defp load_portal_feed_posts(user_id, "discussions", limit, session_context) do
    recommended_posts =
      Integrations.portal_for_you_feed(
        user_id,
        filter: "discussions",
        limit: max(limit * 4, limit + 20),
        session_context: session_context
      )

    community_posts = Enum.filter(recommended_posts, &PostUtilities.community_post?/1)

    public_posts =
      if length(community_posts) < limit do
        Integrations.portal_public_community_posts(
          user_id: user_id,
          limit: max(limit * 2, limit + 20)
        )
      else
        []
      end

    merge_discussion_feed_posts(community_posts, public_posts, limit)
  end

  defp load_portal_feed_posts(user_id, filter, limit, session_context) do
    recommended_posts =
      Integrations.portal_for_you_feed(
        user_id,
        filter: filter,
        limit: limit,
        session_context: session_context
      )

    if length(recommended_posts) < limit do
      fallback_posts = fallback_feed_posts(user_id, filter, limit)
      merge_portal_feed_posts(recommended_posts, fallback_posts, limit)
    else
      recommended_posts
    end
  end

  defp merge_portal_feed_posts(primary_posts, fallback_posts, limit) do
    primary_ids = MapSet.new(Enum.map(primary_posts, & &1.id))

    fallback_posts =
      Enum.reject(fallback_posts, &MapSet.member?(primary_ids, &1.id))

    Enum.take(primary_posts ++ fallback_posts, limit)
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

  @doc false
  def merge_discussion_feed_posts(personalized_posts, public_posts, limit)
      when is_list(personalized_posts) and is_list(public_posts) and is_integer(limit) and
             limit > 0 do
    personalized_posts = Enum.filter(personalized_posts, &PostUtilities.community_post?/1)

    existing_ids = MapSet.new(Enum.map(personalized_posts, & &1.id))

    public_posts =
      public_posts
      |> Enum.filter(&PostUtilities.community_post?/1)
      |> Enum.reject(&MapSet.member?(existing_ids, &1.id))

    Enum.take(personalized_posts ++ public_posts, limit)
  end

  def merge_discussion_feed_posts(personalized_posts, _public_posts, _limit)
      when is_list(personalized_posts) do
    personalized_posts
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

  defp prepend_portal_post(posts, post) when is_list(posts) do
    updated_posts = [post | Enum.reject(posts, &(&1.id == post.id))]
    updated_posts
  end

  defp build_feed_state(all_posts, user_id) do
    all_posts =
      if is_list(all_posts) do
        Elektrine.Repo.preload(all_posts, [:conversation])
      else
        []
      end

    lemmy_counts = load_portal_lemmy_counts(all_posts)

    user_likes = get_user_likes_map(user_id, all_posts)
    user_downvotes = get_user_downvotes_map(user_id, all_posts)

    post_interactions = get_portal_post_interactions(all_posts, user_likes, user_downvotes)

    user_boosts = get_user_boosts_map(user_id, all_posts)
    user_saves = get_user_saves(user_id, all_posts)
    user_follows = get_user_follows(user_id, all_posts)
    pending_follows = get_pending_follows(user_id, all_posts)
    post_reactions = get_post_reactions(all_posts)

    %{
      all_posts: all_posts,
      user_likes: user_likes,
      user_downvotes: user_downvotes,
      post_interactions: post_interactions,
      user_boosts: user_boosts,
      user_saves: user_saves,
      lemmy_counts: lemmy_counts,
      user_follows: user_follows,
      pending_follows: pending_follows,
      post_reactions: post_reactions
    }
  end

  defp load_portal_lemmy_counts(posts) when is_list(posts) do
    activitypub_ids =
      posts
      |> Enum.map(&Map.get(&1, :activitypub_id))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    case activitypub_ids do
      [] ->
        %{}

      ids ->
        {counts, _comments} = LemmyCache.get_cached_data(ids)
        LemmyCache.schedule_refresh(ids)
        counts
    end
  end

  defp load_portal_lemmy_counts(_), do: %{}

  defp get_portal_post_interactions(posts, user_likes, user_downvotes) do
    Map.new(posts, fn post ->
      interaction_key = portal_post_interaction_key(post)

      {interaction_key,
       %{
         liked: Map.get(user_likes, post.id, false),
         downvoted: Map.get(user_downvotes, post.id, false),
         like_delta: 0
       }}
    end)
  end

  defp portal_post_interaction_key(%{activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "",
       do: activitypub_id

  defp portal_post_interaction_key(%{id: id}) when is_integer(id), do: Integer.to_string(id)

  defp register_post_state(socket, %{id: message_id}) when is_integer(message_id) do
    socket
    |> update(:user_likes, &Map.put_new(&1, message_id, false))
    |> update(:user_downvotes, &Map.put_new(&1, message_id, false))
    |> update(:user_boosts, &Map.put_new(&1, message_id, false))
    |> update(:user_saves, &Map.put_new(&1, message_id, false))
    |> update(:post_reactions, &Map.put_new(&1, message_id, []))
  end

  defp register_post_state(socket, _post), do: socket

  defp remove_portal_post(socket, post_id) do
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
      |> sync_portal_posts_stream()
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

  defp find_portal_post(posts, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    Enum.find_value(posts || [], fn post ->
      cond do
        post.id == normalized_post_id ->
          post

        match?(%{id: ^normalized_post_id}, portal_shared_message(post)) ->
          portal_shared_message(post)

        true ->
          nil
      end
    end)
  end

  defp portal_shared_message(%{shared_message: %Ecto.Association.NotLoaded{}}), do: nil

  defp portal_shared_message(%{shared_message: %{id: id} = shared_message}) when is_integer(id),
    do: shared_message

  defp portal_shared_message(_), do: nil

  defp normalize_post_id(post_id) do
    case parse_positive_int(post_id) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp close_quote_modal(socket) do
    socket
    |> assign(:show_quote_modal, false)
    |> assign(:quote_target_post, nil)
    |> assign(:quote_content, "")
  end

  defp increment_portal_quote_count(socket, message_id) do
    update_portal_post(socket, message_id, fn post ->
      Map.put(post, :quote_count, (post.quote_count || 0) + 1)
    end)
  end

  defp update_portal_post(socket, message_id, updater) when is_function(updater, 1) do
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
    |> sync_portal_posts_stream()
  end

  defp reload_portal_post(message_id) when is_integer(message_id) do
    import Ecto.Query

    from(m in Elektrine.Social.Message,
      where: m.id == ^message_id,
      preload: ^MessagingMessages.timeline_post_preloads()
    )
    |> Repo.one()
    |> case do
      nil -> nil
      message -> Elektrine.Social.Message.decrypt_content(message)
    end
  end

  defp reload_portal_post(_), do: nil

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
    if Elektrine.RuntimeEnv.environment() == :test do
      {:ok, loader.()}
    else
      load_with_timeout_task(key, loader, timeout_ms)
    end
  end

  defp load_with_timeout_task(key, loader, timeout_ms) do
    task = Task.async(loader)
    formatted_key = loader_log_label(key)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          Logger.warning("Portal loader exited (#{formatted_key}): #{inspect(reason)}")
          {:error, reason}

        nil ->
          Logger.warning("Portal loader timed out (#{formatted_key}) after #{timeout_ms}ms")
          {:error, :timeout}
      end
    catch
      :exit, reason ->
        Logger.warning("Portal loader crashed (#{formatted_key}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def loader_log_label(key), do: inspect(key)

  defp get_platform_stats do
    import Ecto.Query
    today_start = NaiveDateTime.utc_now() |> NaiveDateTime.beginning_of_day()

    posts_today =
      from(m in Elektrine.Social.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    week_start = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 24 * 60 * 60)

    posts_this_week =
      from(m in Elektrine.Social.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    active_users =
      from(m in Elektrine.Social.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at) and not is_nil(m.sender_id),
        select: m.sender_id,
        distinct: true
      )
      |> Elektrine.Repo.all()
      |> length()

    top_post_today =
      from(m in Elektrine.Social.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            m.visibility == "public" and is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.one()

    top_creators =
      from(m in Elektrine.Social.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
            is_nil(m.deleted_at) and not is_nil(m.sender_id),
        group_by: m.sender_id,
        order_by: [desc: count(m.id)],
        limit: 5,
        select: m.sender_id
      )
      |> Elektrine.Repo.all()
      |> Enum.reject(&is_nil/1)
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
      from(m in Elektrine.Social.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    timeline_posts =
      from(m in Elektrine.Social.Message,
        where: m.sender_id == ^user_id and m.post_type == "post" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    gallery_posts =
      from(m in Elektrine.Social.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    discussion_posts =
      from(m in Elektrine.Social.Message,
        where: m.sender_id == ^user_id and m.post_type == "discussion" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    total_likes =
      from(m in Elektrine.Social.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: sum(m.like_count)
      )
      |> Elektrine.Repo.one() || 0

    followers = Elektrine.Profiles.get_follower_count(user_id)
    following = Elektrine.Profiles.get_following_count(user_id)

    top_post =
      from(m in Elektrine.Social.Message,
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

  defp get_user_own_posts(user_id, limit) do
    import Ecto.Query

    preloads = [conversation: []] ++ MessagingMessages.timeline_feed_preloads()

    from(m in Elektrine.Social.Message,
      where:
        m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: ^preloads
    )
    |> Elektrine.Repo.all()
  end

  defp put_remote_follow_override(socket, remote_actor_id, state) do
    update(socket, :remote_follow_overrides, fn overrides ->
      Map.put(overrides || %{}, {:remote, remote_actor_id}, state)
    end)
  end

  defp push_remote_follow_state(socket, remote_actor_id, state) when is_atom(state) do
    push_remote_follow_state(socket, remote_actor_id, Atom.to_string(state))
  end

  defp push_remote_follow_state(socket, remote_actor_id, state) when is_binary(state) do
    push_event(socket, "remote_follow_state_changed", %{
      remote_actor_id: remote_actor_id,
      state: state
    })
  end

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
