defmodule ElektrineSocialWeb.DiscussionsLive.Index do
  use ElektrineSocialWeb, :live_view
  require Logger
  import Ecto.Query, warn: false
  alias Elektrine.ActivityPub.{Actor, Instance}
  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.ActivityPub.LemmyCache
  alias Elektrine.{AppCache, Messaging, Profiles, Repo, Social}
  alias Elektrine.Reputation
  alias Elektrine.Social.Recommendations
  alias ElektrineSocialWeb.Components.Social.PostUtilities
  import ElektrineSocialWeb.Components.Platform.ENav
  import ElektrineSocialWeb.Components.Social.TimelinePost, only: [timeline_post: 1]
  import ElektrineWeb.Live.Helpers.PostStateHelpers, only: [get_post_reactions: 1]
  @community_feed_page_size 20
  @overview_page_size 6
  @session_interest_dwell_ms 10_000
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      if user do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:communities")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")
      end

      send(self(), :load_communities_data)
    end

    socket =
      socket
      |> assign(:page_title, "Communities")
      |> assign(:communities, [])
      |> assign(:followed_remote_communities, [])
      |> assign(:discover_remote_communities, [])
      |> assign(:public_communities, [])
      |> assign(:trending_discussions, [])
      |> assign(:federated_discussions, [])
      |> assign(:followed_community_posts, [])
      |> assign(:recent_activity, [])
      |> assign(:popular_communities, [])
      |> assign(:my_community_posts, [])
      |> assign(:current_view, default_communities_view(user))
      |> assign(:show_create_community, false)
      |> assign(:show_quick_post, false)
      |> assign(:quick_post_content, "")
      |> assign(:quick_post_title, "")
      |> assign(:quick_post_link_url, "")
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
      |> assign(:filtered_discover_remote_communities, [])
      |> assign(:public_fallback_post_ids, MapSet.new())
      |> assign(:joined_community_ids, MapSet.new())
      |> assign(:search_query, "")
      |> assign(:search_scope, "communities")
      |> assign(:search_results, [])
      |> assign(:search_results_by_scope, default_search_results_by_scope())
      |> assign(:searching, false)
      |> assign(:recent_searches, [])
      |> assign(:recent_joins, [])
      |> assign(:because_you_follow, [])
      |> assign(:followed_remote_actor_ids, MapSet.new())
      |> assign(:post_interactions, %{})
      |> assign(:lemmy_counts, %{})
      |> assign(:post_replies, %{})
      |> assign(:post_reactions, %{})
      |> assign(:loading_more, false)
      |> assign(:no_more_posts, false)
      |> assign(:overview_card_limit, @overview_page_size)
      |> assign(:overview_no_more, false)
      |> assign(:feed_sort, "new")
      |> assign(:session_context, default_session_context())
      |> assign(:remote_user_preview, nil)
      |> assign(:remote_user_loading, false)
      |> assign(:show_image_upload_modal, false)
      |> assign(:pending_media_urls, [])
      |> assign(:pending_media_attachments, [])
      |> assign(:pending_media_alt_texts, %{})
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:loading_communities, true)
      |> assign(:has_community_data, Messaging.has_any_communities?())

    socket =
      if user do
        allow_upload(socket, :discussion_attachments,
          accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
          max_entries: 4,
          max_file_size: 50_000_000
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = params["view"] || default_communities_view(socket.assigns[:current_user])

    show_create_community =
      params["composer"] == "community" and not is_nil(socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:current_view, view)
     |> assign(
       :show_create_community,
       show_create_community || socket.assigns.show_create_community
     )}
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: ~p"/communities?view=#{view}")}
  end

  def handle_event("record_dwell_times", %{"views" => views}, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        Enum.reduce(views, socket, fn view, acc ->
          post_id = view["post_id"]

          if post_id do
            Recommendations.record_view_with_dwell(user.id, post_id, %{
              dwell_time_ms: view["dwell_time_ms"],
              scroll_depth: view["scroll_depth"],
              expanded: view["expanded"] || false,
              source: view["source"] || "communities"
            })

            acc
            |> note_community_view_signal(post_id)
            |> maybe_note_community_dwell_interest(post_id, view["dwell_time_ms"])
          else
            acc
          end
        end)
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("record_dwell_time", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user && params["post_id"] do
        Recommendations.record_view_with_dwell(user.id, params["post_id"], %{
          dwell_time_ms: params["dwell_time_ms"],
          scroll_depth: params["scroll_depth"],
          expanded: params["expanded"] || false,
          source: params["source"] || "communities"
        })

        socket
        |> note_community_view_signal(params["post_id"])
        |> maybe_note_community_dwell_interest(params["post_id"], params["dwell_time_ms"])
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("record_dismissal", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user && params["post_id"] && params["type"] do
        Recommendations.record_dismissal(
          user.id,
          params["post_id"],
          params["type"],
          params["dwell_time_ms"]
        )

        socket
        |> note_community_dismissal_signal(params["post_id"])
      else
        socket
      end

    {:noreply, updated_socket}
  end

  def handle_event("update_session_context", params, socket) do
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators
    current_context = socket.assigns[:session_context] || default_session_context()

    updated_context = %{
      current_context
      | liked_hashtags:
          merge_recent_unique(current_context.liked_hashtags, params["liked_hashtags"] || [], 20),
        liked_creators: merge_recent_unique(current_context.liked_creators, liked_creators, 10),
        liked_local_creators:
          merge_recent_unique(current_context.liked_local_creators, liked_local_creators, 10),
        liked_remote_creators:
          merge_recent_unique(
            current_context.liked_remote_creators,
            params["liked_remote_creators"] || [],
            10
          ),
        viewed_posts:
          merge_recent_unique(current_context.viewed_posts, params["viewed_posts"] || [], 50),
        engagement_rate: coerce_float(params["engagement_rate"], current_context.engagement_rate)
    }

    {:noreply,
     socket
     |> assign(:session_context, updated_context)}
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
              {:ok, id} -> find_feed_post_by_message_id(socket, id)
              :error -> nil
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
       socket
       |> assign(:modal_image_index, new_index)
       |> assign(:modal_image_url, new_url)}
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
       socket
       |> assign(:modal_image_index, new_index)
       |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter_by_category", %{"category" => category}, socket) do
    filtered_communities = filter_communities_by_category(socket.assigns.communities, category)

    filtered_public_communities =
      filter_communities_by_category(socket.assigns.public_communities, category)

    filtered_discussions =
      filter_discussions_by_category(socket.assigns.trending_discussions, category)

    filtered_federated_discussions =
      filter_discussions_by_category(socket.assigns.federated_discussions, category)

    filtered_recent_activity =
      filter_activity_by_category(socket.assigns.recent_activity, category)

    filtered_popular_communities =
      filter_popular_communities_by_category(socket.assigns.popular_communities, category)

    filtered_discover_remote_communities =
      filter_communities_by_category(socket.assigns.discover_remote_communities, category)

    filtered_remote_communities =
      filter_communities_by_category(socket.assigns.followed_remote_communities, category)

    filtered_community_posts =
      socket.assigns.followed_community_posts
      |> filter_community_posts_by_category(category)
      |> sort_feed_posts(
        socket.assigns.feed_sort,
        socket.assigns.lemmy_counts,
        socket.assigns.session_context
      )

    overview_data = %{
      filtered_public_communities: filtered_public_communities,
      joined_community_ids: socket.assigns.joined_community_ids,
      filtered_popular_communities: filtered_popular_communities,
      filtered_discussions: filtered_discussions,
      filtered_recent_activity: filtered_recent_activity,
      filtered_federated_discussions: filtered_federated_discussions,
      filtered_remote_communities: filtered_remote_communities,
      filtered_discover_remote_communities: filtered_discover_remote_communities,
      overview_card_limit: socket.assigns.overview_card_limit
    }

    {:noreply,
     socket
     |> assign(:selected_category, category)
     |> assign(:filtered_communities, filtered_communities)
     |> assign(:filtered_public_communities, filtered_public_communities)
     |> assign(:filtered_discussions, filtered_discussions)
     |> assign(:filtered_federated_discussions, filtered_federated_discussions)
     |> assign(:filtered_recent_activity, filtered_recent_activity)
     |> assign(:filtered_popular_communities, filtered_popular_communities)
     |> assign(:filtered_remote_communities, filtered_remote_communities)
     |> assign(:filtered_discover_remote_communities, filtered_discover_remote_communities)
     |> assign(:filtered_community_posts, filtered_community_posts)
     |> assign(:overview_no_more, overview_no_more?(overview_data))}
  end

  def handle_event("set_feed_sort", %{"sort" => sort}, socket) do
    if socket.assigns.feed_sort == sort do
      {:noreply, socket}
    else
      sorted_posts =
        sort_feed_posts(
          socket.assigns.filtered_community_posts,
          sort,
          socket.assigns.lemmy_counts,
          socket.assigns.session_context
        )

      {:noreply,
       socket |> assign(:feed_sort, sort) |> assign(:filtered_community_posts, sorted_posts)}
    end
  end

  def handle_event("load-more", _params, socket) do
    case socket.assigns.current_view do
      "feed" -> handle_event("load_more_posts", %{}, socket)
      "communities" -> handle_event("load_more_overview", %{}, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("load_more_posts", _params, socket) do
    cond do
      socket.assigns.current_view != "feed" ->
        {:noreply, socket}

      socket.assigns.loading_more || socket.assigns.no_more_posts ->
        {:noreply, socket}

      is_nil(socket.assigns.current_user) ->
        {:noreply, socket}

      true ->
        send(self(), :load_more_community_feed_posts)
        {:noreply, assign(socket, :loading_more, true)}
    end
  end

  def handle_event("load_more_overview", _params, socket) do
    if socket.assigns.current_view != "communities" or socket.assigns.overview_no_more do
      {:noreply, socket}
    else
      next_limit = socket.assigns.overview_card_limit + @overview_page_size

      {:noreply,
       socket
       |> assign(:overview_card_limit, next_limit)
       |> assign(:overview_no_more, overview_no_more?(socket.assigns, next_limit))}
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

      cond do
        not Elektrine.Strings.present?(name) ->
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

        not Elektrine.Strings.present?(description) ->
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
              community = Elektrine.Repo.preload(community, :creator)
              joined_community_ids = MapSet.put(socket.assigns.joined_community_ids, community.id)
              updated_communities = [community | socket.assigns.communities]
              updated_public_communities = [community | socket.assigns.public_communities]
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
          communities = get_user_communities(user_id)
          joined_community_ids = MapSet.put(socket.assigns.joined_community_ids, community_id)

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(:joined_community_ids, joined_community_ids)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> assign_personalized_discovery_assigns(user_id)
           |> notify_info("Joined community successfully!")}

        {:error, _reason} ->
          {:noreply, notify_error(socket, "Failed to join community")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to join a community")}
    end
  end

  def handle_event("join_trending_communities", _params, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id

      communities_to_join =
        socket.assigns.filtered_popular_communities
        |> Enum.reject(&MapSet.member?(socket.assigns.joined_community_ids, &1.id))
        |> Enum.take(3)

      case communities_to_join do
        [] ->
          {:noreply, notify_info(socket, "No joinable communities in this category right now")}

        _ ->
          joined_count =
            Enum.count(communities_to_join, fn community ->
              match?({:ok, _}, Messaging.join_conversation(community.id, user_id))
            end)

          if joined_count > 0 do
            send(self(), :load_communities_data)

            {:noreply,
             socket
             |> assign(:loading_communities, true)
             |> notify_info("Joined #{joined_count} trending communities")}
          else
            {:noreply, notify_error(socket, "Failed to join trending communities")}
          end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to join communities")}
    end
  end

  def handle_event("search_communities", %{"query" => query}, socket) do
    {:noreply, run_discovery_search(socket, query)}
  end

  def handle_event("perform_search", params, socket) do
    query = params["query"] || socket.assigns.search_query

    {:noreply,
     socket
     |> run_discovery_search(query)
     |> maybe_store_recent_search(query)}
  end

  def handle_event("clear_community_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:search_results_by_scope, default_search_results_by_scope())
     |> assign(:searching, false)}
  end

  def handle_event("set_search_scope", %{"scope" => scope}, socket) do
    normalized_scope = normalize_search_scope(scope)

    {:noreply,
     socket
     |> assign(:search_scope, normalized_scope)
     |> assign(
       :search_results,
       Map.get(socket.assigns.search_results_by_scope || %{}, normalized_scope, [])
     )}
  end

  def handle_event("run_recent_search", %{"query" => query} = params, socket) do
    scope = normalize_search_scope(params["scope"] || socket.assigns.search_scope)

    {:noreply,
     socket
     |> assign(:search_scope, scope)
     |> run_discovery_search(query)
     |> maybe_store_recent_search(query)}
  end

  def handle_event("follow_remote_group", %{"actor_id" => actor_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      actor_id = String.to_integer(actor_id)

      case Messaging.CommunitySearch.follow_remote_group(user_id, actor_id) do
        {:ok, remote_actor} ->
          communities = get_user_communities(user_id)

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> refresh_remote_community_assigns(user_id)
           |> assign_personalized_discovery_assigns(user_id)
           |> notify_info(
             "Followed federated community !#{remote_actor.username}@#{remote_actor.domain}"
           )}

        :ok ->
          communities = get_user_communities(user_id)

          {:noreply,
           socket
           |> assign(:communities, communities)
           |> assign(
             :filtered_communities,
             filter_communities_by_category(communities, socket.assigns.selected_category)
           )
           |> refresh_remote_community_assigns(user_id)
           |> assign_personalized_discovery_assigns(user_id)
           |> notify_info("Followed federated community")}

        {:error, reason} ->
          {:noreply, notify_error(socket, "Failed to follow community: #{inspect(reason)}")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to follow communities")}
    end
  end

  def handle_event("leave_community", %{"community_id" => community_id}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      community_id = String.to_integer(community_id)

      case Messaging.remove_member_from_conversation(community_id, user_id) do
        {:ok, _} ->
          communities = get_user_communities(user_id)
          joined_community_ids = MapSet.delete(socket.assigns.joined_community_ids, community_id)

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
           |> assign_personalized_discovery_assigns(user_id)
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
          {:noreply,
           socket
           |> refresh_remote_community_assigns(user_id)
           |> assign_personalized_discovery_assigns(user_id)
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
     |> assign(:quick_post_link_url, "")
     |> assign(:quick_post_community_id, nil)
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_attachments, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

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

    alt_texts =
      params
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "alt_text_") end)
      |> Enum.map(fn {key, value} ->
        index = key |> String.replace("alt_text_", "") |> String.to_integer()
        {to_string(index), value}
      end)
      |> Map.new()

    uploaded_files =
      consume_uploaded_entries(socket, :discussion_attachments, fn %{path: path}, entry ->
        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Elektrine.Uploads.upload_discussion_attachment(upload_struct, user.id) do
          {:ok, metadata} -> {:ok, metadata}
          {:error, _reason} -> {:postpone, :error}
        end
      end)

    if Enum.empty?(uploaded_files) do
      {:noreply, put_flash(socket, :error, "Please select files to upload")}
    else
      uploaded_urls =
        uploaded_files
        |> Enum.map(&Map.get(&1, :key))
        |> Enum.filter(&is_binary/1)

      {:noreply,
       socket
       |> assign(:show_image_upload_modal, false)
       |> assign(:pending_media_urls, uploaded_urls)
       |> assign(:pending_media_attachments, uploaded_files)
       |> assign(:pending_media_alt_texts, alt_texts)
       |> put_flash(:info, "#{length(uploaded_urls)} file(s) added")}
    end
  end

  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_attachments, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  def handle_event("navigate_to_profile", params, socket) do
    handle = params["handle"] || params["username"]
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: Elektrine.Paths.post_path(post_id))}
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
      case resolve_feed_post(socket, post_id) do
        {:ok, post, message, interaction_key} ->
          updated_socket = apply_feed_vote(socket, interaction_key, "up")
          Social.vote_on_message(socket.assigns.current_user.id, message.id, "up")

          {:noreply,
           updated_socket
           |> note_community_positive_signal(post)}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    end
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
      case resolve_feed_post(socket, post_id) do
        {:ok, _post, message, interaction_key} ->
          updated_socket = apply_feed_vote(socket, interaction_key, "up")
          Social.vote_on_message(socket.assigns.current_user.id, message.id, "up")

          {:noreply,
           updated_socket
           |> note_community_dismissal_signal(post_id)}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    end
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
      case resolve_feed_post(socket, post_id) do
        {:ok, _post, message, interaction_key} ->
          updated_socket = apply_feed_vote(socket, interaction_key, "down")
          Social.vote_on_message(socket.assigns.current_user.id, message.id, "down")

          {:noreply, updated_socket}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    end
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
      case resolve_feed_post(socket, post_id) do
        {:ok, post, message, interaction_key} ->
          _post = post
          updated_socket = apply_feed_vote(socket, interaction_key, "down")
          Social.vote_on_message(socket.assigns.current_user.id, message.id, "down")

          {:noreply, updated_socket}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id

      case Enum.find(socket.assigns.filtered_community_posts, fn p ->
             to_string(p.id) == to_string(post_id)
           end) do
        nil ->
          {:noreply, put_flash(socket, :error, "Failed to react to post")}

        post ->
          interaction_id =
            case post.activitypub_id do
              activitypub_id when is_binary(activitypub_id) and activitypub_id != "" ->
                activitypub_id

              _ ->
                post.id
            end

          case ElektrineWeb.Live.PostInteractions.resolve_message_for_interaction(interaction_id) do
            {:ok, message} ->
              alias Elektrine.Messaging.Reactions

              existing_reaction =
                Elektrine.Repo.get_by(Elektrine.Social.MessageReaction,
                  message_id: message.id,
                  user_id: user_id,
                  emoji: emoji
                )

              if existing_reaction do
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
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    end
  end

  def handle_event("create_quick_discussion", params, socket) do
    if socket.assigns.current_user do
      community_selector = params["community_id"]
      title = params["title"]
      content = params["content"]
      link_url = normalize_quick_post_link_url(params["link_url"])
      media_urls = socket.assigns.pending_media_urls
      media_attachments = socket.assigns.pending_media_attachments || []
      alt_texts = socket.assigns.pending_media_alt_texts
      content_empty = not Elektrine.Strings.present?(content)
      has_media = !Enum.empty?(media_urls)
      has_link = Elektrine.Strings.present?(link_url)

      cond do
        not Elektrine.Strings.present?(title) ->
          {:noreply, notify_error(socket, "Title is required")}

        content_empty and not has_media and not has_link ->
          {:noreply, notify_error(socket, "Add content, a link, or media")}

        has_link and not String.starts_with?(link_url, ["http://", "https://"]) ->
          {:noreply,
           notify_error(socket, "Link must be a valid URL starting with http:// or https://")}

        true ->
          case String.split(community_selector, ":", parts: 2) do
            ["local", id_str] ->
              create_local_community_post(
                String.to_integer(id_str),
                title,
                content,
                link_url,
                media_urls,
                media_attachments,
                alt_texts,
                has_media,
                socket
              )

            ["remote", id_str] ->
              create_remote_community_post(
                String.to_integer(id_str),
                title,
                content,
                link_url,
                media_urls,
                media_attachments,
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
    if Elektrine.Strings.present?(remote_handle) do
      socket = assign(socket, remote_user_loading: true, remote_user_preview: nil)

      case parse_and_fetch_remote_user(remote_handle) do
        {:ok, actor} -> send(self(), {:remote_user_fetched, actor})
        {:error, _reason} -> send(self(), {:remote_user_fetch_failed, remote_handle})
      end

      {:noreply, socket}
    else
      {:noreply, assign(socket, remote_user_preview: nil, remote_user_loading: false)}
    end
  end

  def handle_event("follow_remote_user", %{"remote_handle" => _remote_handle}, socket) do
    if socket.assigns.remote_user_preview do
      actor = socket.assigns.remote_user_preview
      current_user = socket.assigns.current_user

      case Profiles.follow_remote_actor(current_user.id, actor.id) do
        {:ok, _follow} ->
          actor_type =
            if actor.actor_type == "Group" do
              "community"
            else
              "user"
            end

          handle_prefix =
            if actor.actor_type == "Group" do
              "!"
            else
              "@"
            end

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
           |> assign(
             :filtered_remote_communities,
             filter_communities_by_category(
               followed_remote_communities,
               socket.assigns.selected_category
             )
           )
           |> notify_info(
             "Following #{actor_type} #{handle_prefix}#{actor.username}@#{actor.domain}!"
           )}

        {:error, :already_following} ->
          {:noreply,
           notify_info(
             socket,
             "You're already following this #{if actor.actor_type == "Group" do
               "community"
             else
               "user"
             end}"
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
         link_url,
         media_urls,
         media_attachments,
         alt_texts,
         has_media,
         socket
       ) do
    message_content =
      [content, if(Elektrine.Strings.present?(link_url), do: link_url, else: nil)]
      |> Enum.filter(&Elektrine.Strings.present?/1)
      |> Enum.join("\n\n")

    case Elektrine.Messaging.create_text_message(
           community_id,
           socket.assigns.current_user.id,
           message_content
         ) do
      {:ok, message} ->
        media_metadata =
          Social.merge_post_media_metadata(%{"attachments" => media_attachments}, alt_texts)

        update_attrs = %{
          post_type: if(Elektrine.Strings.present?(link_url), do: "link", else: "discussion"),
          primary_url: link_url,
          title: title,
          visibility: "public"
        }

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
          |> Elektrine.Social.Message.changeset(update_attrs)
          |> Elektrine.Repo.update()

        case Elektrine.Social.Conversations.get_conversation_basic(community_id) do
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

        community = Enum.find(socket.assigns.communities, &(&1.id == community_id))
        community_name = community.name
        slug = Elektrine.Utils.Slug.discussion_url_slug(updated_message.id, updated_message.title)

        {:noreply,
         socket
         |> assign(:show_quick_post, false)
         |> assign(:quick_post_content, "")
         |> assign(:quick_post_title, "")
         |> assign(:quick_post_link_url, "")
         |> assign(:pending_media_urls, [])
         |> assign(:pending_media_attachments, [])
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
         link_url,
         media_urls,
         media_attachments,
         alt_texts,
         has_media,
         socket
       ) do
    remote_actor = Enum.find(socket.assigns.followed_remote_communities, &(&1.id == actor_id))

    if remote_actor do
      body_content =
        [content, if(Elektrine.Strings.present?(link_url), do: link_url, else: nil)]
        |> Enum.filter(&Elektrine.Strings.present?/1)
        |> Enum.join("\n\n")

      full_content =
        if Elektrine.Strings.present?(title) do
          "**#{title}**

#{body_content}"
        else
          body_content
        end

      media_metadata =
        Social.merge_post_media_metadata(%{"attachments" => media_attachments}, alt_texts)

      post_opts = [
        visibility: "public",
        community_actor_uri: remote_actor.uri,
        post_type: if(Elektrine.Strings.present?(link_url), do: "link", else: "post"),
        primary_url: link_url,
        title: title
      ]

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
           |> assign(:quick_post_link_url, "")
           |> assign(:pending_media_urls, [])
           |> assign(:pending_media_attachments, [])
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
    socket =
      if should_include_post_in_feed?(socket, post) do
        update_feed_with_new_post(socket, post)
      else
        socket
      end

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
    if message_present_in_feed?(socket, message_id) do
      update_vote_counts_fn = fn posts ->
        update_posts_with_vote_counts(posts, message_id, upvotes, downvotes, score)
      end

      socket =
        socket
        |> Phoenix.Component.update(:trending_discussions, update_vote_counts_fn)
        |> Phoenix.Component.update(:filtered_discussions, update_vote_counts_fn)
        |> Phoenix.Component.update(:federated_discussions, update_vote_counts_fn)
        |> Phoenix.Component.update(:filtered_federated_discussions, update_vote_counts_fn)
        |> Phoenix.Component.update(:followed_community_posts, update_vote_counts_fn)
        |> Phoenix.Component.update(:filtered_community_posts, update_vote_counts_fn)

      updated_lemmy_counts =
        update_lemmy_vote_counts(
          socket.assigns.lemmy_counts || %{},
          socket,
          message_id,
          upvotes,
          downvotes,
          score
        )

      updated_post_interactions =
        reset_feed_vote_delta(socket.assigns.post_interactions || %{}, socket, message_id)

      {:noreply,
       socket
       |> assign(:lemmy_counts, updated_lemmy_counts)
       |> assign(:post_interactions, updated_post_interactions)
       |> assign(:filtered_community_posts, socket.assigns.filtered_community_posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    if message_present_in_feed?(socket, message_id) do
      update_counts_fn = fn posts -> update_posts_with_counts(posts, message_id, counts) end

      socket =
        socket
        |> Phoenix.Component.update(:trending_discussions, update_counts_fn)
        |> Phoenix.Component.update(:filtered_discussions, update_counts_fn)
        |> Phoenix.Component.update(:federated_discussions, update_counts_fn)
        |> Phoenix.Component.update(:filtered_federated_discussions, update_counts_fn)
        |> Phoenix.Component.update(:followed_community_posts, update_counts_fn)
        |> Phoenix.Component.update(:filtered_community_posts, update_counts_fn)

      updated_lemmy_counts =
        update_lemmy_counts(socket.assigns.lemmy_counts || %{}, socket, message_id, counts)

      {:noreply,
       socket
       |> assign(:lemmy_counts, updated_lemmy_counts)
       |> assign(:filtered_community_posts, socket.assigns.filtered_community_posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_lemmy_cache, socket) do
    posts = socket.assigns.filtered_community_posts || []

    if posts != [] do
      activitypub_ids =
        posts
        |> Enum.map(& &1.activitypub_id)
        |> Enum.filter(&LemmyApi.community_post_url?/1)

      {counts, comments} = LemmyCache.get_cached_data(activitypub_ids)
      merged_counts = merge_seeded_lemmy_counts(posts, counts)
      LemmyCache.schedule_refresh(activitypub_ids)
      Process.send_after(self(), :refresh_lemmy_cache, 60_000)

      {:noreply,
       socket
       |> assign(:lemmy_counts, merged_counts)
       |> assign(:post_replies, comments)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_reaction_added, reaction}, socket) do
    message_id = reaction.message_id

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

  def handle_info(:load_communities_data, socket) do
    user = socket.assigns[:current_user]

    results = %{
      communities:
        load_with_fallback(
          :communities,
          fn ->
            if user do
              get_user_communities(user.id)
            else
              []
            end
          end,
          []
        ),
      public_communities:
        load_with_fallback(:public_communities, fn -> get_public_communities(24) end, []),
      trending_discussions:
        load_with_fallback(
          :trending_discussions,
          fn -> Social.get_trending_discussions(limit: 24) end,
          []
        ),
      federated_discussions:
        load_with_fallback(
          :federated_discussions,
          fn -> get_federated_discussions(limit: 24) end,
          []
        ),
      followed_remote_communities:
        load_with_fallback(
          :followed_remote_communities,
          fn ->
            if user do
              get_followed_remote_communities(user.id)
            else
              []
            end
          end,
          []
        ),
      discover_remote_communities:
        load_with_fallback(
          :discover_remote_communities,
          fn -> get_discover_remote_communities(user && user.id, limit: 24) end,
          []
        ),
      followed_community_feed_page:
        load_with_fallback(
          :followed_community_feed_page,
          fn -> load_community_feed_page(user, [], limit: @community_feed_page_size) end,
          %{posts: [], public_fallback_ids: MapSet.new()}
        ),
      recent_activity:
        load_with_fallback(
          :recent_activity,
          fn ->
            if user do
              Social.get_recent_community_activity(user.id, limit: 24)
            else
              []
            end
          end,
          []
        ),
      popular_communities:
        load_with_fallback(
          :popular_communities,
          fn -> Social.get_popular_communities_this_week(limit: 24) end,
          []
        ),
      my_community_posts:
        load_with_fallback(
          :my_community_posts,
          fn ->
            if user do
              Social.get_user_community_posts(user.id, limit: 50)
            else
              []
            end
          end,
          []
        )
    }

    communities = results.communities
    public_communities = results.public_communities
    trending_discussions = results.trending_discussions
    federated_discussions = results.federated_discussions
    followed_remote_communities = results.followed_remote_communities
    discover_remote_communities = results.discover_remote_communities
    followed_community_feed_page = results.followed_community_feed_page

    followed_community_posts =
      followed_community_feed_page.posts
      |> ElektrineSocialWeb.Components.Social.PostUtilities.attach_cached_link_previews()

    recent_activity = results.recent_activity
    popular_communities = results.popular_communities
    my_community_posts = results.my_community_posts

    {cached_lemmy_counts, post_replies} =
      load_with_fallback(
        :lemmy_cache,
        fn ->
          if followed_community_posts != [] do
            activitypub_ids =
              followed_community_posts
              |> Enum.map(& &1.activitypub_id)
              |> Enum.filter(&LemmyApi.community_post_url?/1)

            {counts, comments} = LemmyCache.get_cached_data(activitypub_ids)
            LemmyCache.schedule_refresh(activitypub_ids)

            if map_size(comments) < length(activitypub_ids) do
              Process.send_after(self(), :refresh_lemmy_cache, 5000)
            end

            Process.send_after(self(), :refresh_lemmy_cache, 60_000)
            {counts, comments}
          else
            {%{}, %{}}
          end
        end,
        {%{}, %{}}
      )

    lemmy_counts = merge_seeded_lemmy_counts(followed_community_posts, cached_lemmy_counts)

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

    joined_community_ids =
      if user do
        MapSet.new(communities, & &1.id)
      else
        MapSet.new()
      end

    followed_remote_actor_ids = MapSet.new(followed_remote_communities, & &1.id)

    recent_searches =
      if user do
        get_recent_discovery_searches(user.id)
      else
        []
      end

    recent_joins =
      if user do
        get_recent_joins(user.id)
      else
        []
      end

    because_you_follow =
      build_follow_based_suggestions(
        communities,
        followed_remote_communities,
        public_communities,
        discover_remote_communities,
        joined_community_ids,
        followed_remote_actor_ids,
        socket.assigns.selected_category
      )

    filtered_followed_posts =
      followed_community_posts
      |> filter_community_posts_by_category(socket.assigns.selected_category)
      |> sort_feed_posts(socket.assigns.feed_sort, lemmy_counts, socket.assigns.session_context)

    filtered_communities =
      filter_communities_by_category(communities, socket.assigns.selected_category)

    filtered_public_communities =
      filter_communities_by_category(public_communities, socket.assigns.selected_category)

    filtered_discussions =
      filter_discussions_by_category(trending_discussions, socket.assigns.selected_category)

    filtered_federated_discussions =
      filter_discussions_by_category(federated_discussions, socket.assigns.selected_category)

    filtered_recent_activity =
      filter_activity_by_category(recent_activity, socket.assigns.selected_category)

    filtered_popular_communities =
      filter_popular_communities_by_category(
        popular_communities,
        socket.assigns.selected_category
      )

    filtered_remote_communities =
      filter_communities_by_category(
        followed_remote_communities,
        socket.assigns.selected_category
      )

    filtered_discover_remote_communities =
      filter_communities_by_category(
        discover_remote_communities,
        socket.assigns.selected_category
      )

    overview_data = %{
      filtered_public_communities: filtered_public_communities,
      joined_community_ids: joined_community_ids,
      filtered_popular_communities: filtered_popular_communities,
      filtered_discussions: filtered_discussions,
      filtered_recent_activity: filtered_recent_activity,
      filtered_federated_discussions: filtered_federated_discussions,
      filtered_remote_communities: filtered_remote_communities,
      filtered_discover_remote_communities: filtered_discover_remote_communities,
      overview_card_limit: socket.assigns.overview_card_limit
    }

    {:noreply,
     socket
     |> assign(:communities, communities)
     |> assign(:followed_remote_communities, followed_remote_communities)
     |> assign(:discover_remote_communities, discover_remote_communities)
     |> assign(:public_communities, public_communities)
     |> assign(:trending_discussions, trending_discussions)
     |> assign(:federated_discussions, federated_discussions)
     |> assign(:followed_community_posts, followed_community_posts)
     |> assign(:recent_activity, recent_activity)
     |> assign(:popular_communities, popular_communities)
     |> assign(:my_community_posts, my_community_posts)
     |> assign(:filtered_communities, filtered_communities)
     |> assign(:filtered_public_communities, filtered_public_communities)
     |> assign(:filtered_discussions, filtered_discussions)
     |> assign(:filtered_federated_discussions, filtered_federated_discussions)
     |> assign(:filtered_recent_activity, filtered_recent_activity)
     |> assign(:filtered_popular_communities, filtered_popular_communities)
     |> assign(:filtered_community_posts, filtered_followed_posts)
     |> assign(:filtered_remote_communities, filtered_remote_communities)
     |> assign(:filtered_discover_remote_communities, filtered_discover_remote_communities)
     |> assign(:public_fallback_post_ids, followed_community_feed_page.public_fallback_ids)
     |> assign(:joined_community_ids, joined_community_ids)
     |> assign(:followed_remote_actor_ids, followed_remote_actor_ids)
     |> assign(:recent_searches, recent_searches)
     |> assign(:recent_joins, recent_joins)
     |> assign(:because_you_follow, because_you_follow)
     |> assign(:post_interactions, post_interactions)
     |> assign(:lemmy_counts, lemmy_counts)
     |> assign(:post_replies, post_replies)
     |> assign(:post_reactions, post_reactions)
     |> assign(:no_more_posts, length(followed_community_posts) < @community_feed_page_size)
     |> assign(:overview_no_more, overview_no_more?(overview_data))
     |> assign(:loading_communities, false)}
  end

  def handle_info(:load_more_community_feed_posts, socket) do
    current_posts = socket.assigns.followed_community_posts || []
    before_post = List.last(current_posts)

    feed_page =
      load_community_feed_page(socket.assigns.current_user, current_posts,
        limit: @community_feed_page_size,
        before_post: before_post
      )

    more_posts =
      feed_page.posts
      |> ElektrineSocialWeb.Components.Social.PostUtilities.attach_cached_link_previews()

    merged_posts = merge_loaded_feed_posts(current_posts, more_posts)
    {lemmy_counts, post_replies} = merge_feed_lemmy_cache(socket, more_posts)

    post_interactions =
      Map.merge(
        socket.assigns.post_interactions || %{},
        load_post_interactions(more_posts, socket.assigns.current_user)
      )

    post_reactions =
      Map.merge(socket.assigns.post_reactions || %{}, get_post_reactions(more_posts))

    filtered_posts =
      merged_posts
      |> filter_community_posts_by_category(socket.assigns.selected_category)
      |> sort_feed_posts(
        socket.assigns.feed_sort,
        lemmy_counts,
        socket.assigns.session_context
      )

    {:noreply,
     socket
     |> assign(:loading_more, false)
     |> assign(:no_more_posts, length(more_posts) < @community_feed_page_size)
     |> assign(:followed_community_posts, merged_posts)
     |> Phoenix.Component.update(:public_fallback_post_ids, fn existing_ids ->
       MapSet.union(existing_ids || MapSet.new(), feed_page.public_fallback_ids)
     end)
     |> assign(:filtered_community_posts, filtered_posts)
     |> assign(:lemmy_counts, lemmy_counts)
     |> assign(:post_replies, post_replies)
     |> assign(:post_interactions, post_interactions)
     |> assign(:post_reactions, post_reactions)}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  defp normalize_quick_post_link_url(url) when is_binary(url), do: String.trim(url)
  defp normalize_quick_post_link_url(_), do: ""

  defp update_post_reactions(socket, post_id, reaction, action) do
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, post_id, [])

    updated =
      case action do
        :add ->
          if Enum.any?(post_reactions, fn r ->
               r.emoji == reaction.emoji && r.user_id == reaction.user_id
             end) do
            post_reactions
          else
            [reaction | post_reactions]
          end

        :remove ->
          Enum.reject(post_reactions, fn r ->
            r.emoji == reaction.emoji && r.user_id == reaction.user_id
          end)
      end

    Map.put(current_reactions, post_id, updated)
  end

  defp get_user_communities(user_id) do
    Messaging.list_conversations(user_id)
    |> Enum.filter(&(&1.type == "community"))
    |> Enum.reject(&(&1.is_federated_mirror == true))
  end

  defp get_followed_remote_communities(user_id) do
    from(f in Profiles.Follow,
      join: a in Actor,
      on: f.remote_actor_id == a.id,
      where: f.follower_id == ^user_id and a.actor_type == "Group",
      select: a,
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
  end

  defp assign_personalized_discovery_assigns(socket, user_id) when is_integer(user_id) do
    communities = socket.assigns[:communities] || []
    followed_remote_communities = socket.assigns[:followed_remote_communities] || []
    public_communities = socket.assigns[:public_communities] || []
    discover_remote_communities = socket.assigns[:discover_remote_communities] || []
    joined_community_ids = MapSet.new(communities, & &1.id)
    followed_remote_actor_ids = MapSet.new(followed_remote_communities, & &1.id)

    socket
    |> assign(:joined_community_ids, joined_community_ids)
    |> assign(:followed_remote_actor_ids, followed_remote_actor_ids)
    |> assign(:recent_searches, get_recent_discovery_searches(user_id))
    |> assign(:recent_joins, get_recent_joins(user_id))
    |> assign(
      :because_you_follow,
      build_follow_based_suggestions(
        communities,
        followed_remote_communities,
        public_communities,
        discover_remote_communities,
        joined_community_ids,
        followed_remote_actor_ids,
        socket.assigns.selected_category
      )
    )
  end

  defp assign_personalized_discovery_assigns(socket, _user_id), do: socket

  defp refresh_remote_community_assigns(socket, user_id) do
    followed_remote_communities = get_followed_remote_communities(user_id)
    discover_remote_communities = get_discover_remote_communities(user_id, limit: 8)
    selected_category = socket.assigns.selected_category

    socket
    |> assign(:followed_remote_communities, followed_remote_communities)
    |> assign(:discover_remote_communities, discover_remote_communities)
    |> assign(
      :filtered_remote_communities,
      filter_communities_by_category(followed_remote_communities, selected_category)
    )
    |> assign(
      :filtered_discover_remote_communities,
      filter_communities_by_category(discover_remote_communities, selected_category)
    )
  end

  defp get_discover_remote_communities(user_id, opts) do
    limit = Keyword.get(opts, :limit, 8)

    excluded_actor_ids =
      if is_integer(user_id) do
        from(f in Profiles.Follow,
          where: f.follower_id == ^user_id and not is_nil(f.remote_actor_id),
          select: f.remote_actor_id
        )
        |> Repo.all()
      else
        []
      end

    default_domain = Elektrine.Domains.default_user_handle_domain()

    from(a in Actor,
      where:
        a.actor_type == "Group" and is_nil(a.community_id) and not is_nil(a.domain) and
          a.domain != ^default_domain,
      order_by: [desc: a.last_fetched_at, desc: a.inserted_at],
      limit: ^(limit * 3)
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id in excluded_actor_ids))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  defp run_discovery_search(socket, query) do
    query = query |> to_string() |> String.trim()
    scope = normalize_search_scope(socket.assigns[:search_scope])

    if Elektrine.Strings.present?(query) do
      user = socket.assigns[:current_user]
      user_id = user && user.id

      results_by_scope = %{
        "communities" =>
          Messaging.CommunitySearch.search_communities(query,
            user_id: user_id,
            limit: 20
          ),
        "posts" => search_discovery_posts(query, user, limit: 12),
        "people" => search_discovery_people(query, limit: 12)
      }

      socket
      |> assign(:search_query, query)
      |> assign(:search_results_by_scope, results_by_scope)
      |> assign(:search_results, Map.get(results_by_scope, scope, []))
      |> assign(:searching, false)
    else
      socket
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:search_results_by_scope, default_search_results_by_scope())
      |> assign(:searching, false)
    end
  end

  defp default_search_results_by_scope do
    %{"communities" => [], "posts" => [], "people" => []}
  end

  defp normalize_search_scope(scope) when scope in ["communities", "posts", "people"], do: scope
  defp normalize_search_scope(_), do: "communities"

  defp maybe_store_recent_search(socket, query) do
    user = socket.assigns[:current_user]
    query = query |> to_string() |> String.trim()

    cond do
      !user ->
        socket

      !Elektrine.Strings.present?(query) ->
        socket

      true ->
        recent_searches =
          store_recent_discovery_search(user.id, query, socket.assigns.search_scope)

        assign(socket, :recent_searches, recent_searches)
    end
  end

  defp get_recent_discovery_searches(user_id) do
    case AppCache.get_recent_searches(user_id, fn -> [] end) do
      {:ok, searches} when is_list(searches) -> searches
      _ -> []
    end
  end

  defp store_recent_discovery_search(user_id, query, scope) do
    entry = %{"query" => query, "scope" => normalize_search_scope(scope)}

    recent_searches =
      user_id
      |> get_recent_discovery_searches()
      |> Enum.reject(fn
        %{"query" => existing_query, "scope" => existing_scope} ->
          existing_query == query and existing_scope == entry["scope"]

        _ ->
          false
      end)
      |> then(&[entry | &1])
      |> Enum.take(8)

    case Cachex.put(:app_cache, {:recent_searches, user_id}, recent_searches,
           ttl: :timer.hours(1)
         ) do
      {:ok, true} -> recent_searches
      {:ok, _} -> recent_searches
      _ -> recent_searches
    end
  end

  defp search_discovery_people(query, opts) do
    limit = Keyword.get(opts, :limit, 12)

    Reputation.search_public_users(query, limit)
    |> Enum.map(fn person ->
      %{
        id: person.id,
        title: blank_to(person.display_name, "@#{person.username}"),
        handle: person.handle || person.username,
        username: person.username,
        trust_level: person.trust_level,
        avatar_url: person.avatar_url,
        url: "/#{person.handle || person.username}"
      }
    end)
  end

  defp search_discovery_posts(query, user, opts) do
    limit = Keyword.get(opts, :limit, 12)
    query_term = "%#{Elektrine.TextHelpers.sanitize_search_term(query)}%"

    local_posts =
      query_term
      |> local_post_search_query(user)
      |> order_by([m], desc: m.inserted_at, desc: m.id)
      |> limit(^limit)
      |> preload([:conversation, :remote_actor])
      |> Repo.all()
      |> Enum.map(&map_local_post_search_result/1)

    remote_posts =
      from(m in Elektrine.Social.Message,
        left_join: a in Actor,
        on: a.id == m.remote_actor_id,
        where:
          m.federated == true and m.visibility in ["public", "unlisted"] and
            is_nil(m.deleted_at) and is_nil(m.reply_to_id),
        where:
          ilike(fragment("COALESCE(?, '')", m.title), ^query_term) or
            ilike(fragment("COALESCE(?, '')", m.content), ^query_term) or
            ilike(fragment("COALESCE(?, '')", a.username), ^query_term) or
            ilike(fragment("COALESCE(?, '')", a.display_name), ^query_term),
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^limit,
        preload: [remote_actor: []]
      )
      |> Repo.all()
      |> Enum.map(&map_remote_post_search_result/1)

    (local_posts ++ remote_posts)
    |> Enum.uniq_by(& &1.url)
    |> Enum.sort_by(&DateTime.to_unix(ensure_datetime(&1.inserted_at)), :desc)
    |> Enum.take(limit)
  end

  defp local_post_search_query(query_term, nil) do
    from(m in Elektrine.Social.Message,
      join: c in Elektrine.Social.Conversation,
      on: c.id == m.conversation_id,
      where:
        c.type == "community" and c.is_public == true and is_nil(m.deleted_at) and
          is_nil(m.reply_to_id),
      where:
        ilike(fragment("COALESCE(?, '')", m.title), ^query_term) or
          ilike(fragment("COALESCE(?, '')", m.content), ^query_term) or
          ilike(c.name, ^query_term)
    )
  end

  defp local_post_search_query(query_term, user) do
    from(m in Elektrine.Social.Message,
      join: c in Elektrine.Social.Conversation,
      on: c.id == m.conversation_id,
      left_join: cm in Elektrine.Social.ConversationMember,
      on: cm.conversation_id == c.id and cm.user_id == ^user.id,
      where:
        c.type == "community" and is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
          (c.is_public == true or (not is_nil(cm.id) and is_nil(cm.left_at))),
      where:
        ilike(fragment("COALESCE(?, '')", m.title), ^query_term) or
          ilike(fragment("COALESCE(?, '')", m.content), ^query_term) or
          ilike(c.name, ^query_term)
    )
  end

  defp map_local_post_search_result(post) do
    %{
      id: "local-post-#{post.id}",
      kind: :local,
      title: discussion_title(post),
      preview:
        PostUtilities.render_content_preview(
          post.content,
          PostUtilities.get_instance_domain(post),
          160
        ),
      community_label: discussion_community_label(post),
      url: discussion_route(post),
      inserted_at: post.inserted_at,
      metric: "#{post.reply_count || 0} replies"
    }
  end

  defp map_remote_post_search_result(post) do
    %{
      id: "remote-post-#{post.id}",
      kind: :remote,
      title: discussion_title(post),
      preview:
        PostUtilities.render_content_preview(
          post.content,
          PostUtilities.get_instance_domain(post),
          160
        ),
      community_label: discussion_community_label(post),
      url: Elektrine.Paths.post_path(post),
      inserted_at: post.inserted_at,
      metric: "#{post.reply_count || 0} replies"
    }
  end

  defp get_recent_joins(user_id) do
    local_joins =
      from(cm in Elektrine.Social.ConversationMember,
        join: c in Elektrine.Social.Conversation,
        on: c.id == cm.conversation_id,
        where:
          cm.user_id == ^user_id and is_nil(cm.left_at) and c.type == "community" and
            (is_nil(c.is_federated_mirror) or c.is_federated_mirror == false),
        order_by: [desc: cm.joined_at],
        limit: 6,
        select: %{joined_at: cm.joined_at, community: c}
      )
      |> Repo.all()
      |> Enum.map(fn %{joined_at: joined_at, community: community} ->
        %{joined_at: joined_at, community_id: community.id, community: community}
      end)
      |> preload_recent_join_communities()
      |> Enum.map(fn %{joined_at: joined_at, community: community} ->
        %{kind: :local, item: community, joined_at: joined_at}
      end)

    remote_joins =
      from(f in Profiles.Follow,
        join: a in Actor,
        on: f.remote_actor_id == a.id,
        where: f.follower_id == ^user_id and a.actor_type == "Group",
        order_by: [desc: f.inserted_at],
        limit: 6,
        select: %{joined_at: f.inserted_at, actor: a}
      )
      |> Repo.all()
      |> Enum.map(fn %{joined_at: joined_at, actor: actor} ->
        %{kind: :remote, item: actor, joined_at: joined_at}
      end)

    (local_joins ++ remote_joins)
    |> Enum.sort_by(&DateTime.to_unix(ensure_datetime(&1.joined_at)), :desc)
    |> Enum.take(6)
  end

  defp preload_recent_join_communities(joins) do
    community_ids = Enum.map(joins, & &1.community_id)

    communities_by_id =
      Elektrine.Social.Conversation
      |> where([c], c.id in ^community_ids)
      |> Repo.all()
      |> Repo.preload([:creator, :remote_group_actor])
      |> Map.new(&{&1.id, &1})

    Enum.map(joins, fn join ->
      Map.put(join, :community, Map.get(communities_by_id, join.community_id, join.community))
    end)
  end

  defp build_follow_based_suggestions(
         communities,
         followed_remote_communities,
         public_communities,
         discover_remote_communities,
         joined_community_ids,
         followed_remote_actor_ids,
         selected_category
       ) do
    ranked_categories =
      top_followed_categories(communities, followed_remote_communities, selected_category)

    local_suggestions =
      public_communities
      |> Enum.reject(&MapSet.member?(joined_community_ids, &1.id))
      |> Enum.filter(&(community_category(&1) in ranked_categories))
      |> Enum.map(fn community ->
        %{kind: :local, item: community, reason: follow_reason_for(community_category(community))}
      end)

    remote_suggestions =
      discover_remote_communities
      |> Enum.reject(&MapSet.member?(followed_remote_actor_ids, &1.id))
      |> Enum.filter(&(community_category(&1) in ranked_categories))
      |> Enum.map(fn actor ->
        %{kind: :remote, item: actor, reason: follow_reason_for(community_category(actor))}
      end)

    (local_suggestions ++ remote_suggestions)
    |> Enum.uniq_by(fn suggestion -> {suggestion.kind, suggestion.item.id} end)
    |> Enum.take(4)
  end

  defp top_followed_categories(communities, followed_remote_communities, selected_category) do
    categories =
      (communities ++ followed_remote_communities)
      |> Enum.map(&community_category/1)
      |> Enum.reject(&(&1 in [nil, "", "all"]))

    ranked_categories =
      categories
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_category, count} -> -count end)
      |> Enum.map(&elem(&1, 0))

    case selected_category do
      "all" -> ranked_categories
      category -> Enum.filter(ranked_categories, &(&1 == category))
    end
  end

  defp follow_reason_for(category) do
    "Because you follow #{category |> to_string() |> String.replace("_", " ")} communities"
  end

  defp remote_community_followers(%Actor{} = actor) do
    actor.metadata
    |> follower_collection_total()
    |> parse_remote_community_count()
  end

  defp remote_community_followers(_), do: 0

  defp follower_collection_total(metadata) when is_map(metadata) do
    followers = Map.get(metadata, "followers") || Map.get(metadata, :followers)

    case followers do
      %{} = collection ->
        Map.get(collection, "totalItems") || Map.get(collection, :totalItems)

      _ ->
        Map.get(metadata, "followers_count") || Map.get(metadata, :followers_count) ||
          Map.get(metadata, "subscriber_count") || Map.get(metadata, :subscriber_count)
    end
  end

  defp follower_collection_total(_), do: nil

  defp parse_remote_community_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_remote_community_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_remote_community_count(_), do: 0

  defp ensure_datetime(%DateTime{} = value), do: value
  defp ensure_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp ensure_datetime(_), do: DateTime.utc_now()

  defp get_followed_community_posts(user_id, opts) do
    limit = Keyword.get(opts, :limit, 20)
    before_post = Keyword.get(opts, :before_post)

    joined_community_ids =
      from(cm in Elektrine.Social.ConversationMember,
        join: c in Elektrine.Social.Conversation,
        on: c.id == cm.conversation_id,
        where: cm.user_id == ^user_id and is_nil(cm.left_at) and c.type == "community",
        select: c.id
      )
      |> Repo.all()
      |> Enum.uniq()

    followed_groups_from_follows =
      from(f in Profiles.Follow,
        join: a in Actor,
        on: f.remote_actor_id == a.id,
        where: f.follower_id == ^user_id and a.actor_type == "Group",
        select: %{id: a.id, uri: a.uri}
      )
      |> Repo.all()

    federated_mirror_memberships =
      from(cm in Elektrine.Social.ConversationMember,
        join: c in Elektrine.Social.Conversation,
        on: c.id == cm.conversation_id,
        left_join: a in Actor,
        on: c.remote_group_actor_id == a.id,
        where:
          cm.user_id == ^user_id and is_nil(cm.left_at) and c.type == "community" and
            c.is_federated_mirror == true,
        select: %{
          conversation_id: c.id,
          remote_actor_id: c.remote_group_actor_id,
          remote_uri: fragment("COALESCE(?, ?)", a.uri, c.federated_source)
        }
      )
      |> Repo.all()

    followed_actor_ids =
      followed_groups_from_follows
      |> Enum.map(& &1.id)
      |> Kernel.++(Enum.map(federated_mirror_memberships, & &1.remote_actor_id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    followed_uris =
      followed_groups_from_follows
      |> Enum.map(& &1.uri)
      |> Kernel.++(Enum.map(federated_mirror_memberships, & &1.remote_uri))
      |> Enum.map(&Elektrine.Strings.present/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if Enum.empty?(joined_community_ids) and Enum.empty?(followed_actor_ids) and
         Enum.empty?(followed_uris) do
      []
    else
      community_filter = dynamic([_m], false)

      community_filter =
        if Enum.empty?(joined_community_ids) do
          community_filter
        else
          dynamic([m], ^community_filter or m.conversation_id in ^joined_community_ids)
        end

      community_filter =
        if Enum.empty?(followed_actor_ids) do
          community_filter
        else
          dynamic(
            [m],
            ^community_filter or m.remote_actor_id in ^followed_actor_ids
          )
        end

      community_filter =
        if Enum.empty?(followed_uris) do
          community_filter
        else
          dynamic(
            [m],
            ^community_filter or
              fragment("?->>'community_actor_uri' = ANY(?)", m.media_metadata, ^followed_uris)
          )
        end

      query =
        Elektrine.Social.Message
        |> where(
          [m],
          m.visibility == "public" and is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
            fragment("?->>'inReplyTo' IS NULL OR ? IS NULL", m.media_metadata, m.media_metadata)
        )
        |> where([m], ^community_filter)

      query = maybe_apply_feed_cursor(query, before_post)

      query
      |> order_by([m], desc: m.inserted_at, desc: m.id)
      |> limit(^limit)
      |> preload([:conversation, :remote_actor, :hashtags, :link_preview])
      |> Repo.all()
    end
  end

  defp load_community_feed_page(nil, _existing_posts, opts) do
    _limit = Keyword.get(opts, :limit, @community_feed_page_size)
    %{posts: [], public_fallback_ids: MapSet.new()}
  end

  defp load_community_feed_page(user, existing_posts, opts) do
    limit = Keyword.get(opts, :limit, @community_feed_page_size)
    before_post = Keyword.get(opts, :before_post)

    followed_posts =
      get_followed_community_posts(user.id,
        limit: limit,
        before_post: before_post
      )

    remaining = limit - length(followed_posts)

    if remaining <= 0 do
      %{posts: followed_posts, public_fallback_ids: MapSet.new()}
    else
      exclude_ids =
        existing_posts
        |> Enum.map(& &1.id)
        |> Kernel.++(Enum.map(followed_posts, & &1.id))

      public_before_post =
        if followed_posts == [] do
          nil
        else
          before_post
        end

      public_posts =
        get_public_community_feed_posts(
          limit: remaining,
          before_post: public_before_post,
          exclude_ids: exclude_ids
        )

      %{
        posts: followed_posts ++ public_posts,
        public_fallback_ids: MapSet.new(Enum.map(public_posts, & &1.id))
      }
    end
  end

  defp get_public_community_feed_posts(opts) do
    limit = Keyword.get(opts, :limit, @community_feed_page_size)
    before_post = Keyword.get(opts, :before_post)
    exclude_ids = Keyword.get(opts, :exclude_ids, [])

    query =
      Elektrine.Social.Message
      |> join(:left, [m], c in Elektrine.Social.Conversation, on: c.id == m.conversation_id)
      |> where(
        [m, c],
        m.visibility == "public" and is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)) and
          is_nil(m.reply_to_id) and fragment("(?->>'inReplyTo' IS NULL)", m.media_metadata) and
          (c.type == "community" or
             fragment("?->>'community_actor_uri' IS NOT NULL", m.media_metadata))
      )

    query = maybe_apply_feed_cursor(query, before_post)
    query = exclude_blocked_instances(query)

    query =
      if exclude_ids == [] do
        query
      else
        where(query, [m, _c], m.id not in ^exclude_ids)
      end

    query
    |> order_by([m, _c], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> preload([:conversation, :remote_actor, :hashtags, :link_preview])
    |> Repo.all()
  end

  defp maybe_apply_feed_cursor(query, %{inserted_at: inserted_at, id: id})
       when not is_nil(inserted_at) and is_integer(id) do
    where(
      query,
      [m],
      m.inserted_at < ^inserted_at or (m.inserted_at == ^inserted_at and m.id < ^id)
    )
  end

  defp maybe_apply_feed_cursor(query, %{id: id}) when is_integer(id) do
    where(query, [m], m.id < ^id)
  end

  defp maybe_apply_feed_cursor(query, _), do: query

  defp merge_loaded_feed_posts(existing_posts, more_posts) do
    (existing_posts ++ more_posts)
    |> Enum.uniq_by(& &1.id)
  end

  defp merge_feed_lemmy_cache(socket, more_posts) do
    activitypub_ids =
      more_posts
      |> Enum.map(& &1.activitypub_id)
      |> Enum.filter(&LemmyApi.community_post_url?/1)

    if activitypub_ids == [] do
      {socket.assigns.lemmy_counts || %{}, socket.assigns.post_replies || %{}}
    else
      {counts, comments} = LemmyCache.get_cached_data(activitypub_ids)
      LemmyCache.schedule_refresh(activitypub_ids)

      if map_size(comments) < length(activitypub_ids) do
        Process.send_after(self(), :refresh_lemmy_cache, 5000)
      end

      Process.send_after(self(), :refresh_lemmy_cache, 60_000)

      seeded_counts = merge_seeded_lemmy_counts(more_posts, counts)

      {
        Map.merge(socket.assigns.lemmy_counts || %{}, seeded_counts),
        Map.merge(socket.assigns.post_replies || %{}, comments)
      }
    end
  end

  defp merge_seeded_lemmy_counts(posts, lemmy_counts)
       when is_list(posts) and is_map(lemmy_counts) do
    Map.merge(seed_lemmy_counts(posts), lemmy_counts)
  end

  defp merge_seeded_lemmy_counts(posts, _lemmy_counts) when is_list(posts) do
    seed_lemmy_counts(posts)
  end

  defp seed_lemmy_counts(posts) when is_list(posts) do
    Enum.reduce(posts, %{}, fn post, acc ->
      activitypub_id = Map.get(post, :activitypub_id)

      if LemmyApi.community_post_url?(activitypub_id) do
        Map.put(acc, activitypub_id, %{
          upvotes: seeded_vote_count(post, :upvotes),
          downvotes: seeded_vote_count(post, :downvotes),
          score: seeded_score(post),
          comments: seeded_comment_count(post)
        })
      else
        acc
      end
    end)
  end

  defp seeded_vote_count(post, field) when is_map(post) do
    case Map.get(post, field) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp seeded_score(post) when is_map(post) do
    cond do
      is_integer(Map.get(post, :score)) ->
        post.score

      is_integer(Map.get(post, :upvotes)) or is_integer(Map.get(post, :downvotes)) ->
        (Map.get(post, :upvotes) || 0) - (Map.get(post, :downvotes) || 0)

      is_integer(Map.get(post, :like_count)) ->
        post.like_count

      true ->
        0
    end
  end

  defp seeded_comment_count(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    case Map.get(post, :reply_count) do
      value when is_integer(value) and value >= 0 -> value
      _ -> parse_seeded_count(metadata["original_reply_count"])
    end
  end

  defp parse_seeded_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_seeded_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp parse_seeded_count(_), do: 0

  defp overview_no_more?(source, limit \\ nil) do
    limit = limit || source[:overview_card_limit] || @overview_page_size

    discover_public_communities =
      (source[:filtered_public_communities] || [])
      |> Enum.reject(&MapSet.member?(source[:joined_community_ids] || MapSet.new(), &1.id))

    discover_cards =
      build_discovery_cards(
        source[:filtered_popular_communities] || [],
        discover_public_communities
      )

    active_cards =
      build_active_thread_cards(
        source[:filtered_discussions] || [],
        source[:filtered_recent_activity] || [],
        source[:filtered_federated_discussions] || []
      )

    remote_communities = source[:filtered_discover_remote_communities] || []

    limit >= length(discover_cards) && limit >= length(active_cards) &&
      limit >= length(remote_communities)
  end

  defp get_public_communities(limit) do
    from(c in Elektrine.Social.Conversation,
      where:
        c.type == "community" and c.is_public == true and
          (is_nil(c.is_federated_mirror) or c.is_federated_mirror == false),
      order_by: [
        desc: c.member_count,
        desc: c.last_message_at
      ],
      limit: ^limit,
      preload: [:creator, :remote_group_actor]
    )
    |> Elektrine.Repo.all()
  end

  defp filter_communities_by_category(communities, "all") do
    communities
  end

  defp filter_communities_by_category(communities, category) do
    Enum.filter(communities, fn community -> community_category(community) == category end)
  end

  defp filter_discussions_by_category(discussions, "all") do
    discussions
  end

  defp filter_discussions_by_category(discussions, category) do
    Enum.filter(discussions, fn discussion -> community_category(discussion) == category end)
  end

  defp filter_activity_by_category(activity, "all") do
    activity
  end

  defp filter_activity_by_category(activity, category) do
    Enum.filter(activity, fn item -> community_category(item) == category end)
  end

  defp filter_popular_communities_by_category(communities, "all") do
    communities
  end

  defp filter_popular_communities_by_category(communities, category) do
    Enum.filter(communities, fn community -> community.category == category end)
  end

  defp get_federated_discussions(opts) do
    import Ecto.Query
    limit = Keyword.get(opts, :limit, 10)

    from(m in Elektrine.Social.Message,
      join: a in Elektrine.ActivityPub.Actor,
      on: a.id == m.remote_actor_id,
      where:
        m.federated == true and m.visibility == "public" and is_nil(m.deleted_at) and
          is_nil(m.reply_to_id) and a.actor_type == "Group",
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [remote_actor: [], hashtags: [], link_preview: []]
    )
    |> exclude_blocked_instances()
    |> Elektrine.Repo.all()
  end

  defp exclude_blocked_instances(query) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_instance in Instance,
      on:
        blocked_instance.blocked == true and
          (fragment("lower(?)", blocked_instance.domain) ==
             fragment("lower(?)", remote_actor.domain) or
             fragment(
               "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
               blocked_instance.domain,
               remote_actor.domain,
               blocked_instance.domain
             )),
      where: is_nil(remote_actor.id) or is_nil(blocked_instance.id)
    )
  end

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

  defp infer_community_category(_) do
    "general"
  end

  defp community_category(%Elektrine.Social.Conversation{community_category: category})
       when is_binary(category),
       do: category

  defp community_category(%Actor{} = actor), do: infer_community_category(actor.uri)

  defp community_category(%{community_category: category}) when is_binary(category), do: category

  defp community_category(%{category: category}) when is_binary(category), do: category

  defp community_category(%{community: community}), do: community_category(community)
  defp community_category(%{remote_actor: actor}), do: community_category(actor)
  defp community_category(_), do: "general"

  defp filter_community_posts_by_category(posts, "all") do
    posts
  end

  defp filter_community_posts_by_category(posts, category) do
    Enum.filter(posts, fn post ->
      community_uri = get_in(post.media_metadata, ["community_actor_uri"]) || ""
      infer_community_category(community_uri) == category
    end)
  end

  defp sort_feed_posts(posts, "new", lemmy_counts, session_context) do
    now = NaiveDateTime.utc_now()

    Enum.sort(posts, fn a, b ->
      a_score = community_rank_score(a, "new", lemmy_counts, session_context, now)
      b_score = community_rank_score(b, "new", lemmy_counts, session_context, now)

      cond do
        a_score > b_score ->
          true

        a_score < b_score ->
          false

        true ->
          a_inserted_at = normalize_inserted_at(Map.get(a, :inserted_at))
          b_inserted_at = normalize_inserted_at(Map.get(b, :inserted_at))

          case NaiveDateTime.compare(a_inserted_at, b_inserted_at) do
            :gt -> true
            :lt -> false
            :eq -> Map.get(a, :id, 0) >= Map.get(b, :id, 0)
          end
      end
    end)
  end

  defp sort_feed_posts(posts, "top", lemmy_counts, session_context) do
    now = NaiveDateTime.utc_now()

    Enum.sort_by(
      posts,
      fn post -> community_rank_score(post, "top", lemmy_counts, session_context, now) end,
      :desc
    )
  end

  defp sort_feed_posts(posts, "hot", lemmy_counts, session_context) do
    now = NaiveDateTime.utc_now()

    Enum.sort_by(
      posts,
      fn post -> community_rank_score(post, "hot", lemmy_counts, session_context, now) end,
      :desc
    )
  end

  defp sort_feed_posts(posts, "comments", lemmy_counts, session_context) do
    now = NaiveDateTime.utc_now()

    Enum.sort_by(
      posts,
      fn post -> community_rank_score(post, "comments", lemmy_counts, session_context, now) end,
      :desc
    )
  end

  defp sort_feed_posts(posts, _, _lemmy_counts, _session_context) do
    posts
  end

  defp community_base_score(post, "new", lemmy_counts, now) do
    recency_boost_for_post(post, now) * 3 +
      community_base_score(post, "hot", lemmy_counts, now) * 0.25
  end

  defp community_base_score(post, "top", lemmy_counts, _now) do
    case Map.get(lemmy_counts, post.activitypub_id) do
      %{score: score} -> score
      _ -> post.like_count || 0
    end
  end

  defp community_base_score(post, "hot", lemmy_counts, now) do
    score =
      case Map.get(lemmy_counts, post.activitypub_id) do
        %{score: s, comments: c} -> s + c * 2
        _ -> (post.like_count || 0) + (post.reply_count || 0) * 2 + (post.share_count || 0) * 3
      end

    hours_ago = NaiveDateTime.diff(now, normalize_inserted_at(post.inserted_at), :hour)
    decay = :math.pow(0.5, max(hours_ago, 0) / 14)
    score * decay + recency_boost_for_post(post, now)
  end

  defp community_base_score(post, "comments", lemmy_counts, _now) do
    case Map.get(lemmy_counts, post.activitypub_id) do
      %{comments: comments} -> comments
      _ -> post.reply_count || 0
    end
  end

  defp community_rank_score(post, sort, lemmy_counts, session_context, now) do
    community_base_score(post, sort, lemmy_counts, now) +
      community_personalization_score(post, session_context) *
        community_personalization_weight(sort)
  end

  defp community_personalization_weight("hot"), do: 1.0
  defp community_personalization_weight("comments"), do: 0.5
  defp community_personalization_weight(_sort), do: 0.35

  defp community_personalization_score(post, session_context) do
    session_context = session_context || default_session_context()
    hashtags = extract_post_hashtags(post)
    hashtag_matches = Enum.count(hashtags, &(&1 in (session_context.liked_hashtags || [])))

    creator_bonus =
      cond do
        post.federated && post.remote_actor_id in (session_context.liked_remote_creators || []) ->
          28

        !post.federated && post.sender_id in (session_context.liked_local_creators || []) ->
          28

        true ->
          0
      end

    viewed_penalty =
      if normalize_post_id(post.id) in (session_context.viewed_posts || []) do
        -18
      else
        0
      end

    dismissed_penalty =
      if normalize_post_id(post.id) in (session_context.dismissed_posts || []) do
        -80
      else
        0
      end

    underexposed_bonus =
      total_engagement =
      (post.like_count || 0) + (post.reply_count || 0) + (post.share_count || 0)

    if total_engagement <= 8, do: 6, else: 0

    media_bonus = if Enum.empty?(post.media_urls || []), do: 0, else: 4

    creator_bonus + hashtag_matches * 4 + viewed_penalty + dismissed_penalty + underexposed_bonus +
      media_bonus
  end

  defp recency_boost_for_post(post, now) do
    hours_ago = NaiveDateTime.diff(now, normalize_inserted_at(post.inserted_at), :hour)

    cond do
      hours_ago < 4 -> 14
      hours_ago < 12 -> 10
      hours_ago < 24 -> 6
      hours_ago < 72 -> 2
      true -> 0
    end
  end

  defp extract_post_hashtags(post) do
    case Map.get(post, :hashtags) do
      hashtags when is_list(hashtags) -> Enum.map(hashtags, & &1.normalized_name)
      _ -> []
    end
  end

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

  defp note_community_positive_signal(socket, nil), do: socket

  defp note_community_positive_signal(socket, post) do
    session_context =
      socket.assigns[:session_context]
      |> default_if_nil(default_session_context())
      |> merge_community_positive_signal(post, 1)

    assign(socket, :session_context, session_context)
  end

  defp note_community_view_signal(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      session_context =
        socket.assigns[:session_context]
        |> default_if_nil(default_session_context())
        |> merge_community_view_signal(normalized_post_id)

      assign(socket, :session_context, session_context)
    end
  end

  defp maybe_note_community_dwell_interest(socket, post_id, dwell_time_ms) do
    if coerce_int(dwell_time_ms, 0) >= @session_interest_dwell_ms do
      post =
        Enum.find(socket.assigns.followed_community_posts || [], fn candidate ->
          candidate.id == normalize_post_id(post_id)
        end)

      note_community_positive_signal(socket, post)
    else
      socket
    end
  end

  defp note_community_dismissal_signal(socket, post_id) do
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

  defp merge_community_positive_signal(session_context, post, interaction_increment) do
    session_context
    |> Map.update!(:liked_hashtags, &merge_recent_unique(&1, extract_post_hashtags(post), 20))
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
    |> refresh_community_engagement_rate()
  end

  defp merge_community_view_signal(session_context, post_id) do
    already_viewed = post_id in (session_context.viewed_posts || [])

    session_context
    |> Map.update!(:viewed_posts, &merge_recent_unique(&1, [post_id], 50))
    |> Map.update!(:total_views, fn count -> if(already_viewed, do: count, else: count + 1) end)
    |> refresh_community_engagement_rate()
  end

  defp refresh_community_engagement_rate(session_context) do
    total_views =
      max(session_context.total_views || length(session_context.viewed_posts || []), 1)

    total_interactions = session_context.total_interactions || 0
    Map.put(session_context, :engagement_rate, total_interactions / total_views)
  end

  defp normalize_post_id(post_id) when is_integer(post_id) and post_id > 0, do: post_id

  defp normalize_post_id(post_id) when is_binary(post_id) do
    case Integer.parse(post_id) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_post_id(_), do: nil

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

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp normalize_inserted_at(%NaiveDateTime{} = inserted_at), do: inserted_at
  defp normalize_inserted_at(%DateTime{} = inserted_at), do: DateTime.to_naive(inserted_at)
  defp normalize_inserted_at(_), do: ~N[1970-01-01 00:00:00]

  defp update_posts_with_counts(posts, message_id, counts) when is_list(posts) do
    Enum.map(posts, fn post ->
      if is_map(post) && Map.get(post, :id) == message_id do
        post
        |> maybe_put_count(:like_count, counts.like_count)
        |> maybe_put_count(:share_count, counts.share_count)
        |> maybe_put_count(:reply_count, counts.reply_count)
      else
        post
      end
    end)
  end

  defp update_posts_with_counts(posts, _message_id, _counts), do: posts

  defp update_posts_with_vote_counts(posts, message_id, upvotes, downvotes, score)
       when is_list(posts) do
    Enum.map(posts, fn post ->
      if is_map(post) && Map.get(post, :id) == message_id do
        post
        |> maybe_put_count(:upvotes, upvotes)
        |> maybe_put_count(:downvotes, downvotes)
        |> maybe_put_count(:score, score)
      else
        post
      end
    end)
  end

  defp update_posts_with_vote_counts(posts, _message_id, _upvotes, _downvotes, _score), do: posts

  defp maybe_put_count(post, field, value) do
    if Map.has_key?(post, field) do
      Map.put(post, field, value)
    else
      post
    end
  end

  defp update_lemmy_counts(lemmy_counts, socket, message_id, counts) do
    post =
      Enum.find(socket.assigns.followed_community_posts || [], fn candidate ->
        candidate.id == message_id
      end) ||
        Enum.find(socket.assigns.federated_discussions || [], fn candidate ->
          candidate.id == message_id
        end)

    activitypub_id = post && post.activitypub_id

    if is_binary(activitypub_id) do
      existing = Map.get(lemmy_counts, activitypub_id, %{})

      Map.put(
        lemmy_counts,
        activitypub_id,
        existing
        |> Map.put(:score, counts.like_count)
        |> Map.put(:comments, counts.reply_count)
      )
    else
      lemmy_counts
    end
  end

  defp update_lemmy_vote_counts(lemmy_counts, socket, message_id, upvotes, downvotes, score) do
    post = find_feed_post_by_message_id(socket, message_id)
    activitypub_id = post && post.activitypub_id

    if is_binary(activitypub_id) do
      existing = Map.get(lemmy_counts, activitypub_id, %{})

      Map.put(
        lemmy_counts,
        activitypub_id,
        existing
        |> Map.put(:score, score)
        |> Map.put(:upvotes, upvotes)
        |> Map.put(:downvotes, downvotes)
      )
    else
      lemmy_counts
    end
  end

  defp reset_feed_vote_delta(post_interactions, socket, message_id)
       when is_map(post_interactions) do
    case find_feed_post_by_message_id(socket, message_id) do
      nil ->
        post_interactions

      post ->
        [post.activitypub_id, post.id]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&ElektrineWeb.Live.PostInteractions.normalize_key/1)
        |> Enum.uniq()
        |> Enum.reduce(post_interactions, fn key, acc ->
          if Map.has_key?(acc, key) do
            Map.update!(acc, key, &Map.put(&1, :vote_delta, 0))
          else
            acc
          end
        end)
    end
  end

  defp reset_feed_vote_delta(post_interactions, _socket, _message_id), do: post_interactions

  defp find_feed_post_by_message_id(socket, message_id) do
    candidate_lists = [
      socket.assigns.followed_community_posts,
      socket.assigns.filtered_community_posts,
      socket.assigns.federated_discussions,
      socket.assigns.filtered_federated_discussions,
      socket.assigns.trending_discussions,
      socket.assigns.filtered_discussions
    ]

    Enum.find_value(candidate_lists, fn posts ->
      Enum.find(posts || [], fn candidate -> is_map(candidate) && candidate.id == message_id end)
    end)
  end

  defp message_present_in_feed?(socket, message_id) do
    candidate_lists = [
      socket.assigns.followed_community_posts,
      socket.assigns.filtered_community_posts,
      socket.assigns.federated_discussions,
      socket.assigns.filtered_federated_discussions,
      socket.assigns.trending_discussions,
      socket.assigns.filtered_discussions
    ]

    Enum.any?(candidate_lists, fn posts ->
      Enum.any?(posts || [], fn
        post when is_map(post) -> Map.get(post, :id) == message_id
        _ -> false
      end)
    end)
  end

  defp should_include_post_in_feed?(socket, post) when is_map(post) do
    public_root_post?(post) and
      (joined_local_community_post?(socket, post) or followed_remote_community_post?(socket, post))
  end

  defp should_include_post_in_feed?(_socket, _post), do: false

  defp public_root_post?(post) do
    Map.get(post, :visibility) == "public" and is_nil(Map.get(post, :deleted_at)) and
      is_nil(Map.get(post, :reply_to_id)) and
      is_nil(get_in(Map.get(post, :media_metadata) || %{}, ["inReplyTo"]))
  end

  defp joined_local_community_post?(socket, post) do
    conversation_id = Map.get(post, :conversation_id)

    case socket.assigns[:joined_community_ids] do
      %MapSet{} = joined_community_ids ->
        is_integer(conversation_id) and MapSet.member?(joined_community_ids, conversation_id)

      _ ->
        false
    end
  end

  defp followed_remote_community_post?(socket, post) do
    followed_remote_communities = socket.assigns[:followed_remote_communities] || []
    followed_actor_ids = MapSet.new(Enum.map(followed_remote_communities, & &1.id))

    followed_uris =
      followed_remote_communities
      |> Enum.map(& &1.uri)
      |> Enum.map(&Elektrine.Strings.present/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Map.get(post, :remote_actor_id) in followed_actor_ids or
      MapSet.member?(
        followed_uris,
        get_in(Map.get(post, :media_metadata) || %{}, ["community_actor_uri"])
      )
  end

  defp update_feed_with_new_post(socket, post) do
    followed_community_posts =
      prepend_unique_post(socket.assigns.followed_community_posts || [], post)

    filtered_community_posts =
      followed_community_posts
      |> filter_community_posts_by_category(socket.assigns.selected_category)
      |> sort_feed_posts(
        socket.assigns.feed_sort,
        socket.assigns.lemmy_counts,
        socket.assigns.session_context
      )

    socket
    |> assign(:followed_community_posts, followed_community_posts)
    |> assign(:filtered_community_posts, filtered_community_posts)
  end

  defp prepend_unique_post(posts, post) do
    [post | Enum.reject(posts, &(is_map(&1) and Map.get(&1, :id) == Map.get(post, :id)))]
  end

  defp apply_feed_vote(socket, interaction_key, vote_type) when vote_type in ["up", "down"] do
    current_state =
      Map.get(socket.assigns.post_interactions, interaction_key, %{
        liked: false,
        downvoted: false,
        vote: nil,
        vote_delta: 0,
        like_delta: 0
      })

    current_vote = Map.get(current_state, :vote)
    current_vote_delta = Map.get(current_state, :vote_delta, 0)
    new_vote = if current_vote == vote_type, do: nil, else: vote_type
    new_vote_delta = current_vote_delta + vote_value(new_vote) - vote_value(current_vote)

    post_interactions =
      Map.put(socket.assigns.post_interactions, interaction_key, %{
        liked: false,
        downvoted: false,
        vote: new_vote,
        vote_delta: new_vote_delta,
        like_delta: 0
      })

    assign(socket, :post_interactions, post_interactions)
  end

  defp vote_value("up"), do: 1
  defp vote_value("down"), do: -1
  defp vote_value(_), do: 0

  defp load_with_fallback(key, loader, fallback) when is_function(loader, 0) do
    loader.()
  rescue
    exception ->
      Logger.warning("Communities loader failed (#{key}): #{Exception.message(exception)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("Communities loader exited (#{key}): #{inspect(reason)}")
      fallback
  end

  defp load_post_interactions(_posts, nil) do
    %{}
  end

  defp load_post_interactions(posts, user) do
    keyed_posts =
      posts
      |> Enum.map(fn post ->
        key = post.activitypub_id || Integer.to_string(post.id)
        {key, post.id}
      end)
      |> Map.new()

    message_ids = Map.values(keyed_posts)

    if Enum.empty?(message_ids) do
      %{}
    else
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

      Map.new(keyed_posts, fn {interaction_key, message_id} ->
        vote = Map.get(user_votes, message_id)

        {interaction_key,
         %{
           liked: vote == "up" || MapSet.member?(liked_ids, message_id),
           downvoted: vote == "down",
           vote: vote,
           vote_delta: 0,
           like_delta: 0
         }}
      end)
    end
  end

  defp resolve_feed_post(socket, post_id) do
    case Enum.find(socket.assigns.filtered_community_posts, fn post ->
           to_string(post.id) == to_string(post_id)
         end) do
      nil ->
        :error

      post ->
        interaction_id = post.activitypub_id || post.id

        case ElektrineWeb.Live.PostInteractions.resolve_message_for_interaction(interaction_id) do
          {:ok, message} ->
            {:ok, post, message, post.activitypub_id || Integer.to_string(post.id)}

          {:error, _} ->
            :error
        end
    end
  end

  defp default_communities_view(_user), do: "feed"

  defp format_compact_number(value) when is_integer(value) and value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 1)}M"
  end

  defp format_compact_number(value) when is_integer(value) and value >= 1_000 do
    "#{Float.round(value / 1_000, 1)}K"
  end

  defp format_compact_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_compact_number(_), do: "0"

  defp community_route(%Elektrine.Social.Conversation{} = community),
    do: ~p"/communities/#{community.name}"

  defp community_route(%Actor{} = actor), do: "/remote/!#{actor.username}@#{actor.domain}"
  defp community_route(%{community: community}), do: community_route(community)
  defp community_route(%{remote_actor: actor}), do: community_route(actor)
  defp community_route(%{name: name}) when is_binary(name), do: ~p"/communities/#{name}"

  defp community_address(%Elektrine.Social.Conversation{} = community) do
    slug =
      community.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    "!#{slug}@#{Elektrine.Domains.default_user_handle_domain()}"
  end

  defp community_address(%Actor{} = actor), do: "!#{actor.username}@#{actor.domain}"
  defp community_address(%{community: community}), do: community_address(community)
  defp community_address(%{remote_actor: actor}), do: community_address(actor)

  defp community_address(%{name: name}) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    "!#{slug}@#{Elektrine.Domains.default_user_handle_domain()}"
  end

  defp community_category_label(%Elektrine.Social.Conversation{} = community) do
    community |> community_category() |> String.replace("_", " ") |> String.capitalize()
  end

  defp community_category_label(%Actor{} = actor) do
    actor |> community_category() |> String.replace("_", " ") |> String.capitalize()
  end

  defp community_category_label(%{category: category}) when is_binary(category) do
    category |> String.replace("_", " ") |> String.capitalize()
  end

  defp community_category_label(%{community: community}), do: community_category_label(community)
  defp community_category_label(%{remote_actor: actor}), do: community_category_label(actor)
  defp community_category_label(_), do: "General"

  defp community_activity_text(%Elektrine.Social.Conversation{} = community) do
    if community.last_message_at do
      "Active #{Elektrine.Social.time_ago_in_words(community.last_message_at)}"
    else
      nil
    end
  end

  defp community_activity_text(%{weekly_posts: weekly_posts}) when is_integer(weekly_posts) do
    "#{weekly_posts} posts this week"
  end

  defp community_activity_text(_), do: nil

  defp community_display_name_markup(%Elektrine.Social.Conversation{} = community) do
    escape_markup(community.name)
  end

  defp community_display_name_markup(%Actor{} = actor) do
    display_name = normalize_markup_text(actor.display_name)

    if display_name do
      ElektrineWeb.HtmlHelpers.render_actor_display_name(actor)
    else
      escape_markup(humanize_community_name(actor.username))
    end
  end

  defp community_display_name_markup(%{community: community}),
    do: community_display_name_markup(community)

  defp community_display_name_markup(%{remote_actor: actor}),
    do: community_display_name_markup(actor)

  defp community_display_name_markup(%{name: name}) when is_binary(name), do: escape_markup(name)
  defp community_display_name_markup(_), do: escape_markup("Community")

  defp community_creator_markup(%Elektrine.Social.Conversation{} = community) do
    if Ecto.assoc_loaded?(community.creator) && community.creator do
      escape_markup(community.creator.display_name || community.creator.username)
    else
      nil
    end
  end

  defp community_creator_markup(%Actor{} = actor) do
    ElektrineWeb.HtmlHelpers.render_actor_display_name(actor)
  end

  defp community_creator_markup(%{community: community}), do: community_creator_markup(community)
  defp community_creator_markup(%{remote_actor: actor}), do: community_creator_markup(actor)
  defp community_creator_markup(_), do: nil

  defp humanize_community_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[_-]+/, " ")
    |> String.trim()
  end

  defp build_discovery_cards(spotlight_communities, discover_public_communities) do
    [
      {:popular, spotlight_communities},
      {:open, discover_public_communities}
    ]
    |> Enum.reduce({%{}, []}, fn {tag, communities}, {cards, order} ->
      Enum.reduce(communities, {cards, order}, fn community, {cards, order} ->
        key = discovery_card_key(community)

        case cards do
          %{^key => card} ->
            {Map.put(cards, key, %{card | tags: Enum.uniq(card.tags ++ [tag])}), order}

          _ ->
            {Map.put(cards, key, %{community: community, tags: [tag]}), order ++ [key]}
        end
      end)
    end)
    |> then(fn {cards, order} -> Enum.map(order, &Map.fetch!(cards, &1)) end)
  end

  defp discovery_card_key(%Elektrine.Social.Conversation{} = community),
    do: {:community, community.id}

  defp discovery_card_key(%{id: id, name: _name}) when is_integer(id), do: {:community, id}
  defp discovery_card_key(%Actor{} = actor), do: {:actor, actor.id}
  defp discovery_card_key(%{name: name}) when is_binary(name), do: {:name, name}

  defp discovery_card_tags(%{tags: tags}) do
    tags
    |> Enum.map(fn
      :popular -> "Popular"
      :open -> "Open"
    end)
  end

  defp discovery_card_meta_markup(%{community: community, tags: tags}) do
    base_meta = ["#{format_compact_number(community.member_count || 0)} members"]
    base_meta = Enum.map(base_meta, &escape_markup/1)

    base_meta =
      if :popular in tags do
        base_meta ++ [escape_markup("#{community.weekly_posts || 0} posts this week")]
      else
        base_meta
      end

    case community_creator_markup(community) do
      creator when is_binary(creator) -> base_meta ++ [escape_markup("by ") <> creator]
      _ -> base_meta
    end
  end

  defp escape_markup(text) when is_binary(text) do
    text |> html_escape() |> safe_to_string()
  end

  defp escape_markup(_), do: ""

  defp normalize_markup_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_markup_text(_), do: nil

  defp build_active_thread_cards(trending_threads, recent_threads, federated_threads) do
    [
      {:trending, trending_threads},
      {:recent, recent_threads},
      {:remote, federated_threads}
    ]
    |> Enum.reduce({%{}, []}, fn {kind, posts}, {cards, order} ->
      Enum.reduce(posts, {cards, order}, fn post, {cards, order} ->
        key = active_thread_key(post)

        case cards do
          %{^key => card} ->
            {Map.put(cards, key, %{card | kinds: Enum.uniq(card.kinds ++ [kind])}), order}

          _ ->
            {Map.put(cards, key, %{post: post, kinds: [kind]}), order ++ [key]}
        end
      end)
    end)
    |> then(fn {cards, order} -> Enum.map(order, &Map.fetch!(cards, &1)) end)
  end

  defp active_thread_key(post), do: post.activitypub_id || {:post, post.id}

  defp active_thread_labels(%{kinds: kinds}) do
    kinds
    |> Enum.map(fn
      :trending -> "Trending"
      :recent -> "Recent"
      :remote -> "Remote"
    end)
  end

  defp active_thread_metric(%{post: post, kinds: kinds}) do
    cond do
      :trending in kinds ->
        "#{format_compact_number(post.like_count || post.score || 0)} votes"

      :recent in kinds ->
        "#{post.reply_count || 0} replies"

      true ->
        "#{post.reply_count || 0} replies"
    end
  end

  defp discussion_route(post) do
    case local_community_conversation(post) do
      %{name: community_name} ->
        slug =
          Elektrine.Utils.Slug.discussion_url_slug(
            post.id,
            PostUtilities.plain_text_content(post.title) |> blank_to("discussion")
          )

        ~p"/communities/#{community_name}/post/#{slug}"

      _ ->
        Elektrine.Paths.post_path(post.id)
    end
  end

  defp discussion_community_label(post) do
    cond do
      community = local_community_conversation(post) ->
        "!#{community.name}"

      community_uri = get_in(post.media_metadata || %{}, ["community_actor_uri"]) ->
        extract_remote_community_display(community_uri)

      post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        "!#{post.remote_actor.username}@#{post.remote_actor.domain}"

      true ->
        "Community"
    end
  end

  defp discussion_title(post) do
    post.title
    |> PostUtilities.plain_text_content()
    |> blank_to("Untitled discussion")
  end

  defp local_community_conversation(%{conversation: %{type: "community"} = conversation}),
    do: conversation

  defp local_community_conversation(_), do: nil

  defp extract_remote_community_display(community_uri) when is_binary(community_uri) do
    uri = URI.parse(community_uri)
    path_parts = String.split(uri.path || "", "/") |> Enum.reject(&(&1 == ""))
    community_name = List.last(path_parts) || "community"
    "!#{community_name}@#{uri.host}"
  end

  defp extract_remote_community_display(_), do: "Community"

  defp blank_to("", fallback), do: fallback
  defp blank_to(nil, fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_positive_int(_), do: :error

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_non_negative_int(_, default), do: default

  defp parse_and_fetch_remote_user(remote_handle) do
    handle =
      remote_handle |> String.trim_leading("@") |> String.trim_leading("!") |> String.trim()

    case String.split(handle, "@") do
      [username, domain] when username != "" and domain != "" ->
        acct = "#{username}@#{domain}"

        case Elektrine.ActivityPub.Fetcher.webfinger_lookup(acct) do
          {:ok, actor_uri} ->
            Elektrine.ActivityPub.fetch_and_cache_actor(actor_uri, allow_recovery: false)

          {:error, _} ->
            case Elektrine.ActivityPub.Fetcher.webfinger_lookup("!#{acct}") do
              {:ok, actor_uri} ->
                Elektrine.ActivityPub.fetch_and_cache_actor(actor_uri, allow_recovery: false)

              error ->
                error
            end
        end

      _ ->
        {:error, :invalid_handle}
    end
  end

  defp error_to_string(:too_large) do
    "File is too large (max 50MB)"
  end

  defp error_to_string(:too_many_files) do
    "Too many files (max 4)"
  end

  defp error_to_string(:not_accepted) do
    "Invalid file type"
  end

  defp error_to_string(err) do
    "Upload error: #{inspect(err)}"
  end
end
