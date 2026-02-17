defmodule ElektrineWeb.DiscussionsLive.Index do
  use ElektrineWeb, :live_view
  require Logger

  import Ecto.Query, warn: false
  alias Elektrine.{Social, Messaging, Profiles, Repo}
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.LemmyCache
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.LemmyPost
  import ElektrineWeb.Live.Helpers.PostStateHelpers, only: [get_post_reactions: 1]

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      if user do
        # Subscribe to community updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:communities")
        # Subscribe to all discussion activity for live updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")
        # Subscribe to public timeline for reaction updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")
      end

      # Trigger async data loading
      send(self(), :load_communities_data)
    end

    socket =
      socket
      |> assign(:page_title, "Communities")
      |> assign(:communities, [])
      |> assign(:followed_remote_communities, [])
      |> assign(:public_communities, [])
      |> assign(:trending_discussions, [])
      |> assign(:federated_discussions, [])
      |> assign(:followed_community_posts, [])
      |> assign(:recent_activity, [])
      |> assign(:popular_communities, [])
      |> assign(:my_community_posts, [])
      |> assign(:current_view, "feed")
      |> assign(:show_create_community, false)
      |> assign(:show_quick_post, false)
      |> assign(:quick_post_content, "")
      |> assign(:quick_post_title, "")
      |> assign(:quick_post_community_id, nil)
      |> assign(:new_community_name, "")
      |> assign(:new_community_description, "")
      |> assign(:new_community_category, "tech")
      |> assign(:selected_category, "all")
      |> assign(:filtered_communities, [])
      |> assign(:filtered_public_communities, [])
      |> assign(:filtered_discussions, [])
      |> assign(:filtered_federated_discussions, [])
      |> assign(:filtered_recent_activity, [])
      |> assign(:filtered_popular_communities, [])
      |> assign(:filtered_community_posts, [])
      |> assign(:filtered_remote_communities, [])
      |> assign(:joined_community_ids, MapSet.new())
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:searching, false)
      |> assign(:post_interactions, %{})
      |> assign(:lemmy_counts, %{})
      |> assign(:post_replies, %{})
      |> assign(:post_reactions, %{})
      |> assign(:feed_sort, "new")
      |> assign(:remote_user_preview, nil)
      |> assign(:remote_user_loading, false)
      |> assign(:show_image_upload_modal, false)
      |> assign(:pending_media_urls, [])
      |> assign(:pending_media_alt_texts, %{})
      |> assign(:loading_communities, true)
      |> assign(:has_community_data, Messaging.has_any_communities?())

    # Allow media uploads for authenticated users
    socket =
      if user do
        allow_upload(socket, :discussion_attachments,
          accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
          max_entries: 4,
          # 50MB
          max_file_size: 50_000_000
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Default to "feed" view when no view param is specified
    view = params["view"] || "feed"

    {:noreply, assign(socket, :current_view, view)}
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    # Use push_patch to update URL so browser back button works
    {:noreply, push_patch(socket, to: ~p"/communities?view=#{view}")}
  end

  # Ignore tracking events from PostClick hook - not needed for communities page
  def handle_event("record_dwell_times", _params, socket), do: {:noreply, socket}
  def handle_event("record_dwell_time", _params, socket), do: {:noreply, socket}
  def handle_event("record_dismissal", _params, socket), do: {:noreply, socket}
  def handle_event("update_session_context", _params, socket), do: {:noreply, socket}
  def handle_event("stop_propagation", _params, socket), do: {:noreply, socket}

  def handle_event("filter_by_category", %{"category" => category}, socket) do
    # Filter all community-related data based on selected category
    filtered_communities = filter_communities_by_category(socket.assigns.communities, category)

    filtered_public_communities =
      filter_communities_by_category(socket.assigns.public_communities, category)

    filtered_discussions =
      filter_discussions_by_category(socket.assigns.trending_discussions, category)

    filtered_federated_discussions = socket.assigns.federated_discussions

    filtered_recent_activity =
      filter_activity_by_category(socket.assigns.recent_activity, category)

    filtered_popular_communities =
      filter_popular_communities_by_category(socket.assigns.popular_communities, category)

    # Filter community feed posts by inferred category
    filtered_community_posts =
      filter_community_posts_by_category(socket.assigns.followed_community_posts, category)

    {:noreply,
     socket
     |> assign(:selected_category, category)
     |> assign(:filtered_communities, filtered_communities)
     |> assign(:filtered_public_communities, filtered_public_communities)
     |> assign(:filtered_discussions, filtered_discussions)
     |> assign(:filtered_federated_discussions, filtered_federated_discussions)
     |> assign(:filtered_recent_activity, filtered_recent_activity)
     |> assign(:filtered_popular_communities, filtered_popular_communities)
     |> assign(:filtered_community_posts, filtered_community_posts)}
  end

  def handle_event("set_feed_sort", %{"sort" => sort}, socket) do
    if socket.assigns.feed_sort == sort do
      {:noreply, socket}
    else
      # Re-sort the filtered posts
      sorted_posts =
        sort_feed_posts(
          socket.assigns.filtered_community_posts,
          sort,
          socket.assigns.lemmy_counts
        )

      {:noreply,
       socket
       |> assign(:feed_sort, sort)
       |> assign(:filtered_community_posts, sorted_posts)}
    end
  end

  def handle_event("toggle_create_community", _params, socket) do
    if socket.assigns.current_user do
      {:noreply, Phoenix.Component.update(socket, :show_create_community, &(!&1))}
    else
      {:noreply, notify_error(socket, "You must be signed in to create a community")}
    end
  end

  def handle_event("create_community", params, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      name = String.trim(params["name"] || "")
      description = String.trim(params["description"] || "")

      # Validate community name - same pattern as usernames
      cond do
        name == "" ->
          {:noreply, notify_error(socket, "Community name is required")}

        String.length(name) < 2 ->
          {:noreply, notify_error(socket, "Community name must be at least 2 characters")}

        String.length(name) > 30 ->
          {:noreply, notify_error(socket, "Community name must be 30 characters or less")}

        not Regex.match?(~r/^[a-zA-Z0-9]+$/, name) ->
          {:noreply,
           notify_error(
             socket,
             "Community name can only contain letters and numbers (no spaces or special characters)"
           )}

        description == "" ->
          {:noreply, notify_error(socket, "Community description is required")}

        true ->
          community_attrs = %{
            name: name,
            description: description,
            type: "community",
            community_category: params["category"],
            is_public: true,
            allow_public_posts: true,
            discussion_style: "forum"
          }

          case Messaging.create_group_conversation(user_id, community_attrs, []) do
            {:ok, community} ->
              # Preload creator for proper display
              community = Elektrine.Repo.preload(community, :creator)

              # Add to joined community IDs
              joined_community_ids = MapSet.put(socket.assigns.joined_community_ids, community.id)

              # Update all relevant lists
              updated_communities = [community | socket.assigns.communities]
              updated_public_communities = [community | socket.assigns.public_communities]

              # Apply category filter if needed
              selected_category = socket.assigns.selected_category

              filtered_communities =
                filter_communities_by_category(updated_communities, selected_category)

              filtered_public_communities =
                filter_communities_by_category(updated_public_communities, selected_category)

              {:noreply,
               socket
               |> assign(:show_create_community, false)
               |> assign(:new_community_name, "")
               |> assign(:new_community_description, "")
               |> assign(:communities, updated_communities)
               |> assign(:public_communities, updated_public_communities)
               |> assign(:filtered_communities, filtered_communities)
               |> assign(:filtered_public_communities, filtered_public_communities)
               |> assign(:joined_community_ids, joined_community_ids)
               |> notify_info("Community created successfully!")
               |> push_navigate(to: ~p"/communities/#{community.name}")}

            {:error, changeset} ->
              # Check for unique constraint error
              if changeset.errors[:name] do
                {:noreply, notify_error(socket, "A community with this name already exists")}
              else
                {:noreply, notify_error(socket, "Failed to create community")}
              end
          end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to create a community")}
    end
  end

  def handle_event("join_community", %{"community_id" => community_id}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      community_id = String.to_integer(community_id)

      case Messaging.join_conversation(community_id, user_id) do
        {:ok, _} ->
          # Refresh communities list
          communities = get_user_communities(user_id)

          # Update joined community IDs
          joined_community_ids = MapSet.put(socket.assigns.joined_community_ids, community_id)

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(:joined_community_ids, joined_community_ids)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> notify_info("Joined community successfully!")}

        {:error, _reason} ->
          {:noreply, notify_error(socket, "Failed to join community")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to join a community")}
    end
  end

  def handle_event("search_communities", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, search_query: "", search_results: [], searching: false)}
    else
      {:noreply,
       socket
       |> assign(:searching, true)
       |> assign(:search_query, query)}
    end
  end

  def handle_event("perform_search", _params, socket) do
    query = socket.assigns.search_query

    results =
      Messaging.CommunitySearch.search_communities(
        query,
        user_id: socket.assigns[:current_user] && socket.assigns.current_user.id,
        limit: 20
      )

    {:noreply,
     socket
     |> assign(:search_results, results)
     |> assign(:searching, false)}
  end

  def handle_event("follow_remote_group", %{"actor_id" => actor_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, notify_error(socket, "You must be signed in to follow communities")}
    else
      user_id = socket.assigns.current_user.id
      actor_id = String.to_integer(actor_id)

      case Messaging.CommunitySearch.follow_remote_group(user_id, actor_id) do
        {:ok, mirror} ->
          # Refresh communities list
          communities = get_user_communities(user_id)
          joined_community_ids = MapSet.put(socket.assigns.joined_community_ids, mirror.id)

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(:joined_community_ids, joined_community_ids)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> notify_info("Followed federated community! Posts will appear here.")}

        {:error, reason} ->
          {:noreply, notify_error(socket, "Failed to follow community: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("leave_community", %{"community_id" => community_id}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      community_id = String.to_integer(community_id)

      case Messaging.remove_member_from_conversation(community_id, user_id) do
        {:ok, _} ->
          # Refresh communities list
          communities = get_user_communities(user_id)

          # Update joined community IDs by removing this community
          joined_community_ids = MapSet.delete(socket.assigns.joined_community_ids, community_id)

          # Also update discover communities if present
          discover_communities =
            if socket.assigns[:discover_communities] do
              socket.assigns.discover_communities
            else
              []
            end

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(:joined_community_ids, joined_community_ids)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> assign(
             :filtered_discover,
             filter_communities_by_category(
               discover_communities,
               socket.assigns.selected_category
             )
           )
           |> notify_info("Left community successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to leave community")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to leave communities")}
    end
  end

  def handle_event("unfollow_remote_community", %{"actor_id" => actor_id}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      actor_id = String.to_integer(actor_id)

      case Profiles.unfollow_remote_actor(user_id, actor_id) do
        {:ok, _} ->
          # Refresh followed remote communities
          followed_remote_communities = get_followed_remote_communities(user_id)

          {:noreply,
           socket
           |> assign(:followed_remote_communities, followed_remote_communities)
           |> notify_info("Unfollowed community")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unfollow community")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in")}
    end
  end

  def handle_event("show_quick_post", _params, socket) do
    if socket.assigns.current_user do
      {:noreply, assign(socket, :show_quick_post, true)}
    else
      {:noreply, notify_error(socket, "You must be signed in to create posts")}
    end
  end

  def handle_event("hide_quick_post", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_quick_post, false)
     |> assign(:quick_post_content, "")
     |> assign(:quick_post_title, "")
     |> assign(:quick_post_community_id, nil)
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  # Media upload handlers
  def handle_event("open_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, true)}
  end

  def handle_event("close_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, false)}
  end

  def handle_event("validate_discussion_upload", _params, socket) do
    {:noreply, socket}
  end

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
      {:noreply, put_flash(socket, :error, "Please select files to upload")}
    else
      {:noreply,
       socket
       |> assign(:show_image_upload_modal, false)
       |> assign(:pending_media_urls, uploaded_files)
       |> assign(:pending_media_alt_texts, alt_texts)
       |> put_flash(:info, "#{length(uploaded_files)} file(s) added")}
    end
  end

  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  def handle_event("navigate_to_profile", params, socket) do
    # Navigate to the user's profile using handle or username
    handle = params["handle"] || params["username"]
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("navigate_to_discussion", %{"community" => community, "slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/communities/#{community}/post/#{slug}")}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: "/remote/post/#{post_id}")}
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Get the post to find its activitypub_id
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id

      if activitypub_id do
        # Optimistic update - update UI immediately
        current_state =
          socket.assigns.post_interactions[activitypub_id] ||
            %{liked: false, downvoted: false, like_delta: 0}

        post_interactions =
          Map.put(socket.assigns.post_interactions, activitypub_id, %{
            liked: true,
            downvoted: false,
            like_delta: Map.get(current_state, :like_delta, 0) + 1
          })

        updated_socket = assign(socket, :post_interactions, post_interactions)

        # Perform database operation in background
        Task.start(fn ->
          case get_or_store_remote_post(activitypub_id) do
            {:ok, message} ->
              Social.like_post(socket.assigns.current_user.id, message.id)

            _ ->
              :ok
          end
        end)

        {:noreply, updated_socket}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      # Get the post to find its activitypub_id
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id

      if activitypub_id do
        # Optimistic update - update UI immediately
        current_state =
          socket.assigns.post_interactions[activitypub_id] ||
            %{liked: false, downvoted: false, like_delta: 0}

        post_interactions =
          Map.put(socket.assigns.post_interactions, activitypub_id, %{
            liked: false,
            downvoted: Map.get(current_state, :downvoted, false),
            like_delta: Map.get(current_state, :like_delta, 0) - 1
          })

        updated_socket = assign(socket, :post_interactions, post_interactions)

        # Perform database operation in background
        Task.start(fn ->
          case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
            nil -> :ok
            message -> Social.unlike_post(socket.assigns.current_user.id, message.id)
          end
        end)

        {:noreply, updated_socket}
      else
        {:noreply, socket}
      end
    end
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Find post and check current like state
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id
      current_state = socket.assigns.post_interactions[activitypub_id] || %{liked: false}
      is_liked = Map.get(current_state, :liked, false)

      if is_liked do
        handle_event("unlike_post", %{"post_id" => post_id}, socket)
      else
        handle_event("like_post", %{"post_id" => post_id}, socket)
      end
    end
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id

      if activitypub_id do
        # Optimistic update - update UI immediately
        current_state =
          socket.assigns.post_interactions[activitypub_id] ||
            %{liked: false, downvoted: false, like_delta: 0}

        # If was liked before, need to account for removing the upvote
        delta_adjustment = if Map.get(current_state, :liked, false), do: -2, else: -1

        post_interactions =
          Map.put(socket.assigns.post_interactions, activitypub_id, %{
            liked: false,
            downvoted: true,
            like_delta: Map.get(current_state, :like_delta, 0) + delta_adjustment
          })

        updated_socket = assign(socket, :post_interactions, post_interactions)

        # Perform database operation in background
        Task.start(fn ->
          case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
            nil -> :ok
            message -> Social.vote_on_message(socket.assigns.current_user.id, message.id, "down")
          end
        end)

        {:noreply, updated_socket}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, socket}
    else
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id

      if activitypub_id do
        # Optimistic update - update UI immediately
        current_state =
          socket.assigns.post_interactions[activitypub_id] ||
            %{liked: false, downvoted: false, like_delta: 0}

        post_interactions =
          Map.put(socket.assigns.post_interactions, activitypub_id, %{
            liked: false,
            downvoted: false,
            like_delta: Map.get(current_state, :like_delta, 0) + 1
          })

        updated_socket = assign(socket, :post_interactions, post_interactions)

        # Perform database operation in background
        Task.start(fn ->
          case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
            nil ->
              :ok

            message ->
              # Remove the vote entirely by voting up then unliking
              Social.vote_on_message(socket.assigns.current_user.id, message.id, "up")
              Social.unlike_post(socket.assigns.current_user.id, message.id)
          end
        end)

        {:noreply, updated_socket}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      # Find the post to get its activitypub_id
      post =
        Enum.find(socket.assigns.filtered_community_posts, fn p ->
          to_string(p.id) == to_string(post_id)
        end)

      activitypub_id = post && post.activitypub_id

      if activitypub_id do
        # Get or create the local message for this remote post
        case Elektrine.ActivityPub.Helpers.get_or_store_remote_post(activitypub_id) do
          {:ok, message} ->
            alias Elektrine.Messaging.Reactions

            # Check if user already has this reaction in the database
            existing_reaction =
              Elektrine.Repo.get_by(
                Elektrine.Messaging.MessageReaction,
                message_id: message.id,
                user_id: user_id,
                emoji: emoji
              )

            if existing_reaction do
              # Remove the existing reaction
              case Reactions.remove_reaction(message.id, user_id, emoji) do
                {:ok, _} ->
                  updated_reactions =
                    update_post_reactions(
                      socket,
                      post.id,
                      %{emoji: emoji, user_id: user_id},
                      :remove
                    )

                  {:noreply, assign(socket, :post_reactions, updated_reactions)}

                {:error, _} ->
                  {:noreply, socket}
              end
            else
              # Add new reaction
              case Reactions.add_reaction(message.id, user_id, emoji) do
                {:ok, reaction} ->
                  reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])
                  updated_reactions = update_post_reactions(socket, post.id, reaction, :add)
                  {:noreply, assign(socket, :post_reactions, updated_reactions)}

                {:error, :rate_limited} ->
                  {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

                {:error, _} ->
                  {:noreply, socket}
              end
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to react to post")}
        end
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("create_quick_discussion", params, socket) do
    if socket.assigns.current_user do
      community_selector = params["community_id"]
      title = params["title"]
      content = params["content"]
      media_urls = socket.assigns.pending_media_urls
      alt_texts = socket.assigns.pending_media_alt_texts

      # Content can be empty if there's media
      content_empty = String.trim(content || "") == ""
      has_media = !Enum.empty?(media_urls)

      if String.trim(title) == "" or (content_empty and not has_media) do
        {:noreply, notify_error(socket, "Title and content (or media) are required")}
      else
        # Parse community selector (local:123 or remote:456)
        case String.split(community_selector, ":", parts: 2) do
          ["local", id_str] ->
            create_local_community_post(
              String.to_integer(id_str),
              title,
              content,
              media_urls,
              alt_texts,
              has_media,
              socket
            )

          ["remote", id_str] ->
            create_remote_community_post(
              String.to_integer(id_str),
              title,
              content,
              media_urls,
              alt_texts,
              has_media,
              socket
            )

          _ ->
            {:noreply, notify_error(socket, "Please select a community")}
        end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to create a discussion")}
    end
  end

  def handle_event("preview_remote_user", %{"remote_handle" => remote_handle}, socket) do
    if String.trim(remote_handle) == "" do
      {:noreply, assign(socket, remote_user_preview: nil, remote_user_loading: false)}
    else
      # Start loading
      socket = assign(socket, remote_user_loading: true, remote_user_preview: nil)

      # Capture LiveView PID
      lv_pid = self()

      # Fetch in background
      Task.start(fn ->
        case parse_and_fetch_remote_user(remote_handle) do
          {:ok, actor} ->
            send(lv_pid, {:remote_user_fetched, actor})

          {:error, _reason} ->
            send(lv_pid, {:remote_user_fetch_failed, remote_handle})
        end
      end)

      {:noreply, socket}
    end
  end

  def handle_event("follow_remote_user", %{"remote_handle" => _remote_handle}, socket) do
    # Use the preview that was already fetched
    if socket.assigns.remote_user_preview do
      actor = socket.assigns.remote_user_preview
      current_user = socket.assigns.current_user

      case Profiles.follow_remote_actor(current_user.id, actor.id) do
        {:ok, _follow} ->
          actor_type = if actor.actor_type == "Group", do: "community", else: "user"
          handle_prefix = if actor.actor_type == "Group", do: "!", else: "@"

          # Refresh followed remote communities if it's a group
          followed_remote_communities =
            if actor.actor_type == "Group" do
              get_followed_remote_communities(current_user.id)
            else
              socket.assigns.followed_remote_communities
            end

          {:noreply,
           socket
           |> assign(:remote_user_preview, nil)
           |> assign(:followed_remote_communities, followed_remote_communities)
           |> assign(:filtered_remote_communities, followed_remote_communities)
           |> notify_info(
             "Following #{actor_type} #{handle_prefix}#{actor.username}@#{actor.domain}!"
           )}

        {:error, :already_following} ->
          {:noreply,
           notify_info(
             socket,
             "You're already following this #{if actor.actor_type == "Group", do: "community", else: "user"}"
           )}

        {:error, reason} ->
          require Logger
          Logger.error("Failed to follow remote actor: #{inspect(reason)}")
          {:noreply, notify_error(socket, "Failed to follow")}
      end
    else
      {:noreply, notify_error(socket, "Please search for a user or community first")}
    end
  end

  defp create_local_community_post(
         community_id,
         title,
         content,
         media_urls,
         alt_texts,
         has_media,
         socket
       ) do
    case Elektrine.Messaging.create_text_message(
           community_id,
           socket.assigns.current_user.id,
           content
         ) do
      {:ok, message} ->
        # Build media metadata with alt texts
        media_metadata =
          if map_size(alt_texts) > 0 do
            %{"alt_texts" => alt_texts}
          else
            %{}
          end

        # Mark as discussion with title and media
        update_attrs = %{
          post_type: "discussion",
          title: title,
          visibility: "public"
        }

        # Add media if present
        update_attrs =
          if has_media do
            update_attrs
            |> Map.put(:message_type, "image")
            |> Map.put(:media_urls, media_urls)
            |> Map.put(:media_metadata, media_metadata)
          else
            update_attrs
          end

        {:ok, updated_message} =
          message
          |> Elektrine.Messaging.Message.changeset(update_attrs)
          |> Elektrine.Repo.update()

        # Federate to ActivityPub if community is public
        Task.start(fn ->
          case Elektrine.Messaging.Conversations.get_conversation_basic(community_id) do
            {:ok, community_conv} ->
              if community_conv.is_public do
                Elektrine.ActivityPub.Outbox.federate_community_post(
                  updated_message,
                  community_conv
                )
              end

            _ ->
              :ok
          end
        end)

        # Navigate to the new discussion
        community = Enum.find(socket.assigns.communities, &(&1.id == community_id))
        community_name = community.name

        # Use friendly URL with slug
        slug = Elektrine.Utils.Slug.discussion_url_slug(updated_message.id, updated_message.title)

        {:noreply,
         socket
         |> assign(:show_quick_post, false)
         |> assign(:quick_post_content, "")
         |> assign(:quick_post_title, "")
         |> assign(:pending_media_urls, [])
         |> assign(:pending_media_alt_texts, %{})
         |> notify_info("Discussion created!")
         |> push_navigate(to: ~p"/communities/#{community_name}/post/#{slug}")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to create discussion")}
    end
  end

  defp create_remote_community_post(
         actor_id,
         title,
         content,
         media_urls,
         alt_texts,
         has_media,
         socket
       ) do
    # Find the remote community actor
    remote_actor = Enum.find(socket.assigns.followed_remote_communities, &(&1.id == actor_id))

    if remote_actor do
      # Build full content with title
      full_content =
        if title != "" do
          "**#{title}**\n\n#{content}"
        else
          content
        end

      # Build media metadata with alt texts
      media_metadata =
        if map_size(alt_texts) > 0 do
          %{"alt_texts" => alt_texts}
        else
          %{}
        end

      post_opts = [
        visibility: "public",
        community_actor_uri: remote_actor.uri
      ]

      # Add media if present
      post_opts =
        if has_media do
          post_opts
          |> Keyword.put(:media_urls, media_urls)
          |> Keyword.put(:media_metadata, media_metadata)
        else
          post_opts
        end

      case Social.create_timeline_post(
             socket.assigns.current_user.id,
             full_content,
             post_opts
           ) do
        {:ok, _post} ->
          {:noreply,
           socket
           |> assign(:show_quick_post, false)
           |> assign(:quick_post_content, "")
           |> assign(:quick_post_title, "")
           |> assign(:pending_media_urls, [])
           |> assign(:pending_media_alt_texts, %{})
           |> notify_info(
             "Post created! It will be federated to #{remote_actor.display_name || remote_actor.username}"
           )
           |> push_navigate(to: "/remote/#{remote_actor.username}@#{remote_actor.domain}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create post")}
      end
    else
      {:noreply, notify_error(socket, "Remote community not found")}
    end
  end

  @impl true
  def handle_info({:remote_user_fetched, actor}, socket) do
    {:noreply, assign(socket, remote_user_preview: actor, remote_user_loading: false)}
  end

  def handle_info({:remote_user_fetch_failed, _handle}, socket) do
    {:noreply,
     socket
     |> assign(:remote_user_loading, false)
     |> put_flash(:error, "Could not find user or community")}
  end

  def handle_info({:new_discussion_post, post}, socket) do
    # Add new discussion posts to trending feed
    if socket.assigns.current_view == "trending" do
      {:noreply,
       Phoenix.Component.update(socket, :trending_discussions, fn posts -> [post | posts] end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:post_voted,
         %{message_id: message_id, upvotes: upvotes, downvotes: downvotes, score: score}},
        socket
      ) do
    # Update vote counts in trending discussions
    if socket.assigns.current_view == "trending" do
      updated_discussions =
        Enum.map(socket.assigns.trending_discussions, fn discussion ->
          if discussion.id == message_id do
            %{discussion | upvotes: upvotes, downvotes: downvotes, score: score}
          else
            discussion
          end
        end)

      {:noreply, assign(socket, :trending_discussions, updated_discussions)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_lemmy_cache, socket) do
    # Periodic refresh - reload from cache and schedule next refresh
    posts = socket.assigns.filtered_community_posts || []

    if posts != [] do
      activitypub_ids =
        posts
        |> Enum.map(& &1.activitypub_id)
        |> Enum.filter(&(&1 && String.contains?(&1, "/post/")))

      {counts, comments} = LemmyCache.get_cached_data(activitypub_ids)

      # Schedule background refresh for any stale entries
      LemmyCache.schedule_refresh(activitypub_ids)

      # Schedule next cache read in 60 seconds
      Process.send_after(self(), :refresh_lemmy_cache, 60_000)

      {:noreply,
       socket
       |> assign(:lemmy_counts, counts)
       |> assign(:post_replies, comments)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_reaction_added, reaction}, socket) do
    # Find the post in our list that matches this message_id
    # The discussions page uses post.id as key, but we need to match by the underlying message
    message_id = reaction.message_id

    # Check if any of our posts correspond to this message
    matching_post =
      Enum.find(socket.assigns.filtered_community_posts, fn post ->
        # For remote posts, check if the message was created from this post's activitypub_id
        case Elektrine.Messaging.get_message(message_id) do
          nil -> false
          msg -> msg.activitypub_id == post.activitypub_id
        end
      end)

    if matching_post do
      current_reactions = Map.get(socket.assigns, :post_reactions, %{})
      post_reactions = Map.get(current_reactions, matching_post.id, [])

      # Add reaction if not already present
      already_present = Enum.any?(post_reactions, fn r -> r.id == reaction.id end)

      updated_reactions =
        if already_present do
          current_reactions
        else
          Map.put(current_reactions, matching_post.id, [reaction | post_reactions])
        end

      {:noreply, assign(socket, :post_reactions, updated_reactions)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_reaction_removed, reaction}, socket) do
    message_id = reaction.message_id

    # Check if any of our posts correspond to this message
    matching_post =
      Enum.find(socket.assigns.filtered_community_posts, fn post ->
        case Elektrine.Messaging.get_message(message_id) do
          nil -> false
          msg -> msg.activitypub_id == post.activitypub_id
        end
      end)

    if matching_post do
      current_reactions = Map.get(socket.assigns, :post_reactions, %{})
      post_reactions = Map.get(current_reactions, matching_post.id, [])

      # Remove the reaction
      updated_post_reactions =
        Enum.reject(post_reactions, fn r ->
          r.emoji == reaction.emoji && r.user_id == reaction.user_id
        end)

      updated_reactions = Map.put(current_reactions, matching_post.id, updated_post_reactions)
      {:noreply, assign(socket, :post_reactions, updated_reactions)}
    else
      {:noreply, socket}
    end
  end

  # Async data loading handler
  def handle_info(:load_communities_data, socket) do
    user = socket.assigns[:current_user]

    # Load each dataset with a fallback so DB pressure does not crash the LiveView.
    # Under federation bursts we can see pool checkout timeouts; failing closed keeps
    # /communities responsive instead of restarting the process on Task.await/2 timeout.
    results = %{
      communities:
        load_with_fallback(:communities, fn ->
          if user, do: get_user_communities(user.id), else: []
        end, []),
      public_communities:
        load_with_fallback(:public_communities, fn -> get_public_communities() end, []),
      trending_discussions:
        load_with_fallback(
          :trending_discussions,
          fn -> Social.get_trending_discussions(limit: 15) end,
          []
        ),
      federated_discussions:
        load_with_fallback(
          :federated_discussions,
          fn -> get_federated_discussions(limit: 10) end,
          []
        ),
      followed_remote_communities:
        load_with_fallback(
          :followed_remote_communities,
          fn -> if user, do: get_followed_remote_communities(user.id), else: [] end,
          []
        ),
      followed_community_posts:
        load_with_fallback(
          :followed_community_posts,
          fn -> if user, do: get_followed_community_posts(user.id, limit: 30), else: [] end,
          []
        ),
      recent_activity:
        load_with_fallback(
          :recent_activity,
          fn -> if user, do: Social.get_recent_community_activity(user.id, limit: 10), else: [] end,
          []
        ),
      popular_communities:
        load_with_fallback(
          :popular_communities,
          fn -> Social.get_popular_communities_this_week(limit: 6) end,
          []
        ),
      my_community_posts:
        load_with_fallback(
          :my_community_posts,
          fn -> if user, do: Social.get_user_community_posts(user.id, limit: 50), else: [] end,
          []
        )
    }

    communities = results.communities
    public_communities = results.public_communities
    trending_discussions = results.trending_discussions
    federated_discussions = results.federated_discussions
    followed_remote_communities = results.followed_remote_communities
    followed_community_posts = results.followed_community_posts
    recent_activity = results.recent_activity
    popular_communities = results.popular_communities
    my_community_posts = results.my_community_posts

    # Load cached Lemmy data immediately (fast DB query)
    # Schedule background refresh for stale entries
    {lemmy_counts, post_replies} =
      load_with_fallback(
        :lemmy_cache,
        fn ->
          if followed_community_posts != [] do
            activitypub_ids =
              followed_community_posts
              |> Enum.map(& &1.activitypub_id)
              |> Enum.filter(&(&1 && String.contains?(&1, "/post/")))

            {counts, comments} = LemmyCache.get_cached_data(activitypub_ids)

            # Schedule background refresh for stale/missing entries
            LemmyCache.schedule_refresh(activitypub_ids)

            # If cache was empty/incomplete, schedule a quick refresh to pick up
            # newly cached data once the background job completes (~5 seconds)
            # Then schedule regular periodic refresh
            if map_size(comments) < length(activitypub_ids) do
              Process.send_after(self(), :refresh_lemmy_cache, 5_000)
            end

            Process.send_after(self(), :refresh_lemmy_cache, 60_000)

            {counts, comments}
          else
            {%{}, %{}}
          end
        end,
        {%{}, %{}}
      )

    post_interactions =
      load_with_fallback(
        :post_interactions,
        fn -> load_post_interactions(followed_community_posts, user) end,
        %{}
      )

    post_reactions =
      load_with_fallback(
        :post_reactions,
        fn -> get_post_reactions(followed_community_posts) end,
        %{}
      )

    # Build a set of joined community IDs for quick lookup
    joined_community_ids =
      if user do
        MapSet.new(communities, & &1.id)
      else
        MapSet.new()
      end

    {:noreply,
     socket
     |> assign(:communities, communities)
     |> assign(:followed_remote_communities, followed_remote_communities)
     |> assign(:public_communities, public_communities)
     |> assign(:trending_discussions, trending_discussions)
     |> assign(:federated_discussions, federated_discussions)
     |> assign(:followed_community_posts, followed_community_posts)
     |> assign(:recent_activity, recent_activity)
     |> assign(:popular_communities, popular_communities)
     |> assign(:my_community_posts, my_community_posts)
     |> assign(:filtered_communities, communities)
     |> assign(:filtered_public_communities, public_communities)
     |> assign(:filtered_discussions, trending_discussions)
     |> assign(:filtered_federated_discussions, federated_discussions)
     |> assign(:filtered_recent_activity, recent_activity)
     |> assign(:filtered_popular_communities, popular_communities)
     |> assign(:filtered_community_posts, followed_community_posts)
     |> assign(:filtered_remote_communities, followed_remote_communities)
     |> assign(:joined_community_ids, joined_community_ids)
     |> assign(:post_interactions, post_interactions)
     |> assign(:lemmy_counts, lemmy_counts)
     |> assign(:post_replies, post_replies)
     |> assign(:post_reactions, post_reactions)
     |> assign(:loading_communities, false)}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  # Helper functions

  defp update_post_reactions(socket, post_id, reaction, action) do
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, post_id, [])

    updated =
      case action do
        :add ->
          # Add the reaction to the list (if not already present)
          if Enum.any?(post_reactions, fn r ->
               r.emoji == reaction.emoji && r.user_id == reaction.user_id
             end) do
            post_reactions
          else
            [reaction | post_reactions]
          end

        :remove ->
          # Remove the reaction from the list
          Enum.reject(post_reactions, fn r ->
            r.emoji == reaction.emoji && r.user_id == reaction.user_id
          end)
      end

    Map.put(current_reactions, post_id, updated)
  end

  defp get_user_communities(user_id) do
    Messaging.list_conversations(user_id)
    |> Enum.filter(&(&1.type == "community"))
  end

  defp get_followed_remote_communities(user_id) do
    # Get all remote Group actors that this user follows
    # Note: Include pending follows since Lemmy may not send Accept
    from(f in Profiles.Follow,
      join: a in Actor,
      on: f.remote_actor_id == a.id,
      where: f.follower_id == ^user_id and a.actor_type == "Group",
      select: a,
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
  end

  defp get_followed_community_posts(user_id, opts) do
    limit = Keyword.get(opts, :limit, 20)

    # Get the URIs of communities the user follows
    # Note: Include pending follows for Group actors since Lemmy may not send Accept
    followed_uris =
      from(f in Profiles.Follow,
        join: a in Actor,
        on: f.remote_actor_id == a.id,
        where: f.follower_id == ^user_id and a.actor_type == "Group",
        select: a.uri
      )
      |> Repo.all()

    if Enum.empty?(followed_uris) do
      []
    else
      # Get posts that have community_actor_uri matching followed community URIs
      from(m in Messaging.Message,
        where:
          m.federated == true and
            m.visibility == "public" and
            is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and
            fragment("?->>'community_actor_uri' = ANY(?)", m.media_metadata, ^followed_uris),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [remote_actor: [], hashtags: [], link_preview: []]
      )
      |> Repo.all()
    end
  end

  defp get_public_communities(limit \\ 10) do
    from(c in Messaging.Conversation,
      where: c.type == "community" and c.is_public == true,
      order_by: [
        # Prioritize local communities over mirrors
        desc: fragment("CASE WHEN ? = false THEN 1 ELSE 0 END", c.is_federated_mirror),
        desc: c.member_count,
        desc: c.last_message_at
      ],
      limit: ^limit,
      preload: [:creator, :remote_group_actor]
    )
    |> Elektrine.Repo.all()
  end

  defp filter_communities_by_category(communities, "all"), do: communities

  defp filter_communities_by_category(communities, category) do
    # Filter communities based on their community_category field
    Enum.filter(communities, fn community ->
      community.community_category == category
    end)
  end

  defp filter_discussions_by_category(discussions, "all"), do: discussions

  defp filter_discussions_by_category(discussions, category) do
    # Filter discussions based on their conversation's community_category
    Enum.filter(discussions, fn discussion ->
      # Check if the discussion has a conversation preloaded and its category matches
      discussion.conversation && discussion.conversation.community_category == category
    end)
  end

  defp filter_activity_by_category(activity, "all"), do: activity

  defp filter_activity_by_category(activity, category) do
    # Filter recent activity based on conversation's community_category
    Enum.filter(activity, fn item ->
      item.conversation && item.conversation.community_category == category
    end)
  end

  defp filter_popular_communities_by_category(communities, "all"), do: communities

  defp filter_popular_communities_by_category(communities, category) do
    # Filter popular communities based on their category field
    # Note: popular_communities returns a map with :category field
    Enum.filter(communities, fn community ->
      community.category == category
    end)
  end

  defp get_federated_discussions(opts) do
    import Ecto.Query
    limit = Keyword.get(opts, :limit, 10)

    # Get federated posts from Group actors only (Lemmy communities, Guppe groups, etc.)
    # Groups are community/forum actors in ActivityPub - perfect for discussions
    from(m in Messaging.Message,
      join: a in Elektrine.ActivityPub.Actor,
      on: a.id == m.remote_actor_id,
      where:
        m.federated == true and
          m.visibility == "public" and
          is_nil(m.deleted_at) and
          is_nil(m.reply_to_id) and
          a.actor_type == "Group",
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [remote_actor: [], hashtags: [], link_preview: []]
    )
    |> Elektrine.Repo.all()
  end

  # Infer category from community name/URI for filtering
  defp infer_community_category(community_uri) when is_binary(community_uri) do
    name = community_uri |> String.downcase()

    cond do
      String.contains?(name, [
        "programming",
        "code",
        "developer",
        "software",
        "linux",
        "python",
        "javascript",
        "rust",
        "elixir"
      ]) ->
        "programming"

      String.contains?(name, [
        "tech",
        "technology",
        "hardware",
        "retrocomputing",
        "computers",
        "android",
        "apple",
        "windows"
      ]) ->
        "tech"

      String.contains?(name, ["meme", "shitpost", "funny", "humor"]) ->
        "memes"

      String.contains?(name, [
        "gaming",
        "games",
        "playstation",
        "xbox",
        "nintendo",
        "steam",
        "pcgaming"
      ]) ->
        "gaming"

      String.contains?(name, ["movie", "film", "cinema"]) ->
        "movies"

      String.contains?(name, ["anime", "manga"]) ->
        "anime"

      String.contains?(name, ["music", "hiphop", "metal", "rock"]) ->
        "music"

      String.contains?(name, ["science", "physics", "chemistry", "biology"]) ->
        "science"

      String.contains?(name, ["space", "astronomy", "nasa"]) ->
        "space"

      String.contains?(name, ["news", "world"]) ->
        "news"

      String.contains?(name, ["politics", "political"]) ->
        "politics"

      String.contains?(name, ["art", "drawing", "illustration"]) ->
        "art"

      String.contains?(name, ["photo", "photography"]) ->
        "photography"

      String.contains?(name, ["food", "cooking", "recipes"]) ->
        "food"

      String.contains?(name, ["fitness", "gym", "workout"]) ->
        "fitness"

      String.contains?(name, ["crypto", "bitcoin", "ethereum"]) ->
        "crypto"

      true ->
        "general"
    end
  end

  defp infer_community_category(_), do: "general"

  # Filter community posts by inferred category
  defp filter_community_posts_by_category(posts, "all"), do: posts

  defp filter_community_posts_by_category(posts, category) do
    Enum.filter(posts, fn post ->
      community_uri = get_in(post.media_metadata, ["community_actor_uri"]) || ""
      infer_community_category(community_uri) == category
    end)
  end

  # Sort feed posts by different criteria
  defp sort_feed_posts(posts, "new", _lemmy_counts) do
    Enum.sort_by(posts, & &1.inserted_at, {:desc, NaiveDateTime})
  end

  defp sort_feed_posts(posts, "top", lemmy_counts) do
    Enum.sort_by(
      posts,
      fn post ->
        # Use Lemmy score if available, otherwise use local like_count
        case Map.get(lemmy_counts, post.activitypub_id) do
          %{score: score} -> score
          _ -> post.like_count || 0
        end
      end,
      :desc
    )
  end

  defp sort_feed_posts(posts, "hot", lemmy_counts) do
    now = NaiveDateTime.utc_now()

    Enum.sort_by(
      posts,
      fn post ->
        # Hot score: combines recency with engagement
        # Based on Reddit's hot algorithm (simplified)
        score =
          case Map.get(lemmy_counts, post.activitypub_id) do
            %{score: s, comments: c} -> s + c * 2
            _ -> (post.like_count || 0) + (post.reply_count || 0) * 2
          end

        # Calculate hours since posted (inserted_at is NaiveDateTime)
        hours_ago = NaiveDateTime.diff(now, post.inserted_at, :hour)

        # Decay factor: newer posts score higher
        # Score decays by half every 12 hours
        decay = :math.pow(0.5, max(hours_ago, 0) / 12)

        # Final hot score
        score * decay
      end,
      :desc
    )
  end

  defp sort_feed_posts(posts, "comments", lemmy_counts) do
    Enum.sort_by(
      posts,
      fn post ->
        # Sort by comment count
        case Map.get(lemmy_counts, post.activitypub_id) do
          %{comments: comments} -> comments
          _ -> post.reply_count || 0
        end
      end,
      :desc
    )
  end

  defp sort_feed_posts(posts, _, _lemmy_counts), do: posts

  defp load_with_fallback(key, loader, fallback) when is_function(loader, 0) do
    try do
      loader.()
    rescue
      exception ->
        Logger.warning(
          "Communities loader failed (#{key}): #{Exception.message(exception)}"
        )

        fallback
    catch
      :exit, reason ->
        Logger.warning("Communities loader exited (#{key}): #{inspect(reason)}")
        fallback
    end
  end

  # Load interaction state (likes/boosts) for posts
  defp load_post_interactions(_posts, nil), do: %{}

  defp load_post_interactions(posts, user) do
    # Get all ActivityPub IDs from posts
    activitypub_ids =
      posts
      |> Enum.map(& &1.activitypub_id)
      |> Enum.filter(& &1)

    if Enum.empty?(activitypub_ids) do
      %{}
    else
      # Find messages that exist locally
      local_messages = Elektrine.Messaging.get_messages_by_activitypub_ids(activitypub_ids)

      # Build a map of activitypub_id => message_id
      message_id_map = Map.new(local_messages, fn msg -> {msg.activitypub_id, msg.id} end)

      # Get all local message IDs
      message_ids = Enum.map(local_messages, & &1.id)

      # Check which posts the user has liked (via PostLike)
      liked_ids =
        if Enum.empty?(message_ids) do
          MapSet.new()
        else
          from(pl in Social.PostLike,
            where: pl.user_id == ^user.id and pl.message_id in ^message_ids,
            select: pl.message_id
          )
          |> Repo.all()
          |> MapSet.new()
        end

      # Get user's votes (upvote/downvote) - maps message_id to vote_type
      user_votes =
        if Enum.empty?(message_ids) do
          %{}
        else
          from(v in Elektrine.Social.MessageVote,
            where: v.user_id == ^user.id and v.message_id in ^message_ids,
            select: {v.message_id, v.vote_type}
          )
          |> Repo.all()
          |> Map.new()
        end

      # Build interaction state map by ActivityPub ID
      Map.new(activitypub_ids, fn activitypub_id ->
        case Map.get(message_id_map, activitypub_id) do
          nil ->
            {activitypub_id, %{liked: false, downvoted: false, like_delta: 0}}

          message_id ->
            vote = Map.get(user_votes, message_id)

            {activitypub_id,
             %{
               # For Lemmy-style posts, "liked" means upvoted
               liked: vote == "up" || MapSet.member?(liked_ids, message_id),
               downvoted: vote == "down",
               like_delta: 0
             }}
        end
      end)
    end
  end

  defp get_or_store_remote_post(activitypub_id) do
    APHelpers.get_or_store_remote_post(activitypub_id)
  end

  defp parse_and_fetch_remote_user(remote_handle) do
    # Handle both user (@user@domain or user@domain) and community (!community@domain or community@domain) formats
    handle =
      remote_handle
      |> String.trim_leading("@")
      |> String.trim_leading("!")
      |> String.trim()

    case String.split(handle, "@") do
      [username, domain] when username != "" and domain != "" ->
        acct = "#{username}@#{domain}"

        # Try WebFinger lookup - will work for both users and communities
        with {:ok, actor_uri} <- Elektrine.ActivityPub.Fetcher.webfinger_lookup(acct),
             {:ok, actor} <- Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
          {:ok, actor}
        else
          {:error, _} ->
            # If normal lookup failed and it might be a community, try with ! prefix
            case Elektrine.ActivityPub.Fetcher.webfinger_lookup("!#{acct}") do
              {:ok, actor_uri} ->
                Elektrine.ActivityPub.get_or_fetch_actor(actor_uri)

              error ->
                error
            end
        end

      _ ->
        {:error, :invalid_handle}
    end
  end

  # Upload error helper
  defp error_to_string(:too_large), do: "File is too large (max 50MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 4)"
  defp error_to_string(:not_accepted), do: "Invalid file type"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"
end
