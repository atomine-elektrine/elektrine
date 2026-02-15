defmodule ElektrineWeb.ListLive.Show do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.Social
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.HtmlHelpers, except: [make_links_and_hashtags_clickable: 1]
  import ElektrineWeb.Live.Helpers.PostStateHelpers

  @impl true
  def mount(%{"id" => list_id}, _session, socket) do
    user = socket.assigns[:current_user]
    list_id = String.to_integer(list_id)

    if !user do
      {:ok, push_navigate(socket, to: ~p"/login")}
    else
      # Try to get as owner first, then as public list
      list = Social.get_user_list(user.id, list_id) || Social.get_public_list(list_id)

      case list do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "List not found")
           |> push_navigate(to: ~p"/lists")}

        list ->
          # Check if user is the owner
          is_owner = list.user_id == user.id

          # Load timeline for this list
          posts = Social.get_list_timeline(list_id, limit: 20)

          # Load replies for posts
          post_ids = Enum.map(posts, & &1.id)

          post_replies =
            Social.get_direct_replies_for_posts(post_ids, user_id: user.id, limit_per_post: 3)

          # Get all message IDs (posts + replies)
          all_reply_ids = post_replies |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
          all_message_ids = post_ids ++ all_reply_ids

          # Get user likes and boosts
          user_likes = get_user_likes(user.id, posts ++ List.flatten(Map.values(post_replies)))
          user_boosts = get_user_boosts(user.id, all_message_ids)

          {:ok,
           socket
           |> assign(:page_title, list.name)
           |> assign(:list, list)
           |> assign(:is_owner, is_owner)
           |> assign(:posts, posts)
           |> assign(:post_replies, post_replies)
           |> assign(:user_likes, user_likes)
           |> assign(:user_boosts, user_boosts)
           |> assign(:show_add_member_form, false)
           |> assign(:add_mode, "search")
           |> assign(:bulk_input, "")
           |> assign(:search_query, "")
           |> assign(:search_results, [])
           |> assign(:reply_to_reply_id, nil)
           |> assign(:reply_content, "")}
      end
    end
  end

  @impl true
  def handle_event("set_add_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :add_mode, mode)}
  end

  def handle_event("update_bulk_input", %{"handles" => handles}, socket) do
    {:noreply, assign(socket, :bulk_input, handles)}
  end

  @impl true
  def handle_event("toggle_add_member_form", _params, socket) do
    {:noreply, assign(socket, :show_add_member_form, !socket.assigns.show_add_member_form)}
  end

  # Handle keyup events with key metadata
  def handle_event("search_users", %{"value" => query}, socket) do
    import Ecto.Query

    query = String.trim(query)

    if String.length(query) < 2 do
      {:noreply, assign(socket, :search_results, [])}
    else
      search_term = "%#{query}%"

      # Search local users
      local_results =
        from(u in Elektrine.Accounts.User,
          where: ilike(u.username, ^search_term) or ilike(u.display_name, ^search_term),
          where: u.banned == false,
          limit: 10,
          preload: [:profile]
        )
        |> Elektrine.Repo.all()
        |> Enum.map(&%{type: :local, user: &1})

      # Search remote actors (if query looks like @user@domain)
      remote_results =
        if String.contains?(query, "@") do
          from(a in Elektrine.ActivityPub.Actor,
            where:
              ilike(a.username, ^search_term) or
                ilike(a.display_name, ^search_term) or
                ilike(a.domain, ^search_term),
            limit: 10
          )
          |> Elektrine.Repo.all()
          |> Enum.map(&%{type: :remote, actor: &1})
        else
          []
        end

      all_results = local_results ++ remote_results

      {:noreply,
       socket
       |> assign(:search_results, all_results)
       |> assign(:search_query, query)}
    end
  end

  # Add remote user by handle (like @user@domain)
  def handle_event("add_remote_user", %{"handle" => handle}, socket) do
    case Elektrine.ActivityPub.FederationHelpers.follow_remote_user(
           socket.assigns.current_user.username,
           handle
         ) do
      {:ok, result} ->
        # Add the remote actor to the list
        case Social.add_to_list(socket.assigns.list.id, %{remote_actor_id: result.remote_actor.id}) do
          {:ok, _} ->
            list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)
            posts = Social.get_list_timeline(socket.assigns.list.id, limit: 20)
            post_ids = Enum.map(posts, & &1.id)

            post_replies =
              Social.get_direct_replies_for_posts(post_ids,
                user_id: socket.assigns.current_user.id,
                limit_per_post: 3
              )

            # Get all message IDs (posts + replies)
            all_reply_ids = post_replies |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
            all_message_ids = post_ids ++ all_reply_ids

            user_likes =
              get_user_likes(
                socket.assigns.current_user.id,
                posts ++ List.flatten(Map.values(post_replies))
              )

            user_boosts = get_user_boosts(socket.assigns.current_user.id, all_message_ids)

            {:noreply,
             socket
             |> assign(:list, list)
             |> assign(:posts, posts)
             |> assign(:post_replies, post_replies)
             |> assign(:user_likes, user_likes)
             |> assign(:user_boosts, user_boosts)
             |> assign(:search_results, [])
             |> assign(:search_query, "")
             |> put_flash(
               :info,
               "Added @#{result.remote_actor.username}@#{result.remote_actor.domain} to list"
             )}

          {:error, reason} ->
            Logger.error("Failed to add to list: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to add to list")}
        end

      {:error, :webfinger_failed} ->
        Logger.warning("WebFinger failed for: #{handle}")

        {:noreply,
         put_flash(socket, :error, "Could not find user. Check the handle and try again.")}

      {:error, :already_following} ->
        # User already followed, just add to list
        case Elektrine.ActivityPub.get_actor_by_username_and_domain(
               String.split(handle, "@") |> Enum.at(0),
               String.split(handle, "@") |> Enum.at(1)
             ) do
          nil ->
            {:noreply, put_flash(socket, :error, "Could not find user")}

          actor ->
            case Social.add_to_list(socket.assigns.list.id, %{remote_actor_id: actor.id}) do
              {:ok, _} ->
                list =
                  Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)

                posts = Social.get_list_timeline(socket.assigns.list.id, limit: 20)
                post_ids = Enum.map(posts, & &1.id)

                post_replies =
                  Social.get_direct_replies_for_posts(post_ids,
                    user_id: socket.assigns.current_user.id,
                    limit_per_post: 3
                  )

                # Get all message IDs (posts + replies)
                all_reply_ids =
                  post_replies |> Map.values() |> List.flatten() |> Enum.map(& &1.id)

                all_message_ids = post_ids ++ all_reply_ids

                user_likes =
                  get_user_likes(
                    socket.assigns.current_user.id,
                    posts ++ List.flatten(Map.values(post_replies))
                  )

                user_boosts = get_user_boosts(socket.assigns.current_user.id, all_message_ids)

                {:noreply,
                 socket
                 |> assign(:list, list)
                 |> assign(:posts, posts)
                 |> assign(:post_replies, post_replies)
                 |> assign(:user_likes, user_likes)
                 |> assign(:user_boosts, user_boosts)
                 |> assign(:search_results, [])
                 |> assign(:search_query, "")
                 |> put_flash(:info, "Added @#{actor.username}@#{actor.domain} to list")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to add to list")}
            end
        end

      {:error, reason} ->
        Logger.error("Failed to add remote user: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to add remote user")}
    end
  end

  # Handle regular form input
  def handle_event("search_users", %{"query" => query}, socket) do
    import Ecto.Query

    query = String.trim(query)

    if String.length(query) < 2 do
      {:noreply, assign(socket, search_results: [])}
    else
      search_term = "%#{query}%"

      # Search local users by username or handle
      local_results =
        from(u in Elektrine.Accounts.User,
          where: ilike(u.username, ^search_term) or ilike(u.handle, ^search_term),
          limit: 10,
          preload: [:profile]
        )
        |> Elektrine.Repo.all()
        |> Enum.map(&%{type: :local, user: &1})

      # Search remote actors
      remote_results =
        from(a in Elektrine.ActivityPub.Actor,
          where: ilike(a.username, ^search_term) or ilike(a.display_name, ^search_term),
          limit: 10
        )
        |> Elektrine.Repo.all()
        |> Enum.map(&%{type: :remote, actor: &1})

      results = local_results ++ remote_results

      {:noreply, assign(socket, search_results: results)}
    end
  end

  def handle_event("add_member", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Social.add_to_list(socket.assigns.list.id, %{user_id: user_id}) do
      {:ok, _} ->
        list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)

        {:noreply,
         socket
         |> assign(:list, list)
         |> assign(:search_results, [])
         |> assign(:search_query, "")
         |> put_flash(:info, "Added to list")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add to list")}
    end
  end

  def handle_event("add_member", %{"remote_actor_id" => remote_actor_id}, socket) do
    remote_actor_id = String.to_integer(remote_actor_id)

    case Social.add_to_list(socket.assigns.list.id, %{remote_actor_id: remote_actor_id}) do
      {:ok, _} ->
        list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)

        {:noreply,
         socket
         |> assign(:list, list)
         |> assign(:search_results, [])
         |> assign(:search_query, "")
         |> put_flash(:info, "Added to list")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add to list")}
    end
  end

  def handle_event("bulk_add_members", _params, socket) do
    require Logger
    handles_text = String.trim(socket.assigns.bulk_input)

    if handles_text == "" do
      {:noreply, put_flash(socket, :error, "Please enter at least one handle")}
    else
      # Parse comma-separated handles
      handles =
        handles_text
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      # Process each handle
      results =
        Enum.map(handles, fn handle ->
          # Remove leading @ if present
          clean_handle = String.trim_leading(handle, "@")

          # Check if it's a fediverse handle (contains @) or local username
          if String.contains?(clean_handle, "@") do
            # Fediverse handle: user@domain
            add_remote_user_to_list(socket, clean_handle)
          else
            # Local username
            add_local_user_to_list(socket, clean_handle)
          end
        end)

      successful = Enum.count(results, &(&1 == :ok))
      total = length(handles)

      # Reload list and posts
      list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)
      posts = Social.get_list_timeline(socket.assigns.list.id, limit: 20)
      post_ids = Enum.map(posts, & &1.id)

      post_replies =
        Social.get_direct_replies_for_posts(post_ids,
          user_id: socket.assigns.current_user.id,
          limit_per_post: 3
        )

      # Get all message IDs (posts + replies)
      all_reply_ids = post_replies |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
      all_message_ids = post_ids ++ all_reply_ids

      user_likes =
        get_user_likes(
          socket.assigns.current_user.id,
          posts ++ List.flatten(Map.values(post_replies))
        )

      user_boosts = get_user_boosts(socket.assigns.current_user.id, all_message_ids)

      {:noreply,
       socket
       |> assign(:list, list)
       |> assign(:posts, posts)
       |> assign(:post_replies, post_replies)
       |> assign(:user_likes, user_likes)
       |> assign(:user_boosts, user_boosts)
       |> assign(:bulk_input, "")
       |> assign(:search_results, [])
       |> put_flash(:info, "Added #{successful}/#{total} users to list")}
    end
  end

  def handle_event("follow_all_members", _params, socket) do
    # Reload list to get fresh members with associations
    list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)
    list_members = list.list_members
    current_user_id = socket.assigns.current_user.id

    # Follow all members
    results =
      Enum.map(list_members, fn member ->
        cond do
          # Local user
          member.user_id && member.user ->
            case Elektrine.Profiles.follow_user(current_user_id, member.user_id) do
              {:ok, _} -> {:ok, member.user.username}
              # Already following is ok
              {:error, _} -> {:ok, member.user.username}
            end

          # Remote actor
          member.remote_actor_id && member.remote_actor ->
            # Already followed when added to list
            {:ok, "@#{member.remote_actor.username}@#{member.remote_actor.domain}"}

          true ->
            {:error, "unknown"}
        end
      end)

    # Count successes
    successful =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    total = length(list_members)

    {:noreply,
     socket
     |> assign(:list, list)
     |> put_flash(:info, "Followed #{successful}/#{total} members")}
  end

  def handle_event("remove_member", %{"member_id" => member_id}, socket) do
    member_id = String.to_integer(member_id)

    case Social.remove_from_list(member_id) do
      {:ok, _} ->
        list = Social.get_user_list(socket.assigns.current_user.id, socket.assigns.list.id)
        posts = Social.get_list_timeline(socket.assigns.list.id, limit: 20)
        post_ids = Enum.map(posts, & &1.id)

        post_replies =
          Social.get_direct_replies_for_posts(post_ids,
            user_id: socket.assigns.current_user.id,
            limit_per_post: 3
          )

        # Get all message IDs (posts + replies)
        all_reply_ids = post_replies |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
        _all_message_ids = post_ids ++ all_reply_ids

        user_likes =
          get_user_likes(
            socket.assigns.current_user.id,
            posts ++ List.flatten(Map.values(post_replies))
          )

        user_boosts = get_user_boosts(socket.assigns.current_user.id, post_ids ++ all_reply_ids)

        {:noreply,
         socket
         |> assign(:list, list)
         |> assign(:posts, posts)
         |> assign(:post_replies, post_replies)
         |> assign(:user_likes, user_likes)
         |> assign(:user_boosts, user_boosts)
         |> put_flash(:info, "Removed from list")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove from list")}
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.current_user.id
    message_id = String.to_integer(message_id)

    case Map.get(socket.assigns.user_likes, message_id, false) do
      true ->
        case Social.unlike_post(user_id, message_id) do
          {:ok, _} ->
            # Update in posts or replies
            {updated_posts, updated_replies} =
              update_message_count(
                socket.assigns.posts,
                socket.assigns.post_replies,
                message_id,
                :like_count,
                -1
              )

            {:noreply,
             socket
             |> assign(:posts, updated_posts)
             |> assign(:post_replies, updated_replies)
             |> assign(:user_likes, Map.put(socket.assigns.user_likes, message_id, false))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unlike post")}
        end

      false ->
        case Social.like_post(user_id, message_id) do
          {:ok, _} ->
            # Update in posts or replies
            {updated_posts, updated_replies} =
              update_message_count(
                socket.assigns.posts,
                socket.assigns.post_replies,
                message_id,
                :like_count,
                1
              )

            {:noreply,
             socket
             |> assign(:posts, updated_posts)
             |> assign(:post_replies, updated_replies)
             |> assign(:user_likes, Map.put(socket.assigns.user_likes, message_id, true))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to like post")}
        end
    end
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.current_user.id
    message_id = String.to_integer(message_id)

    case Map.get(socket.assigns.user_boosts, message_id, false) do
      true ->
        case Social.unboost_post(user_id, message_id) do
          {:ok, _} ->
            # Update in posts or replies
            {updated_posts, updated_replies} =
              update_message_count(
                socket.assigns.posts,
                socket.assigns.post_replies,
                message_id,
                :share_count,
                -1
              )

            {:noreply,
             socket
             |> assign(:posts, updated_posts)
             |> assign(:post_replies, updated_replies)
             |> assign(:user_boosts, Map.put(socket.assigns.user_boosts, message_id, false))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unboost")}
        end

      false ->
        case Social.boost_post(user_id, message_id) do
          {:ok, _} ->
            # Update in posts or replies
            {updated_posts, updated_replies} =
              update_message_count(
                socket.assigns.posts,
                socket.assigns.post_replies,
                message_id,
                :share_count,
                1
              )

            {:noreply,
             socket
             |> assign(:posts, updated_posts)
             |> assign(:post_replies, updated_replies)
             |> assign(:user_boosts, Map.put(socket.assigns.user_boosts, message_id, true))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to boost")}
        end
    end
  end

  def handle_event("navigate_to_post", %{"id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
  end

  def handle_event("open_external_link", %{"url" => url}, socket) do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("show_reply_to_reply_form", %{"reply_id" => reply_id}, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_reply_id, String.to_integer(reply_id))
     |> assign(:reply_content, "")}
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_reply_id, nil)
     |> assign(:reply_content, "")}
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("create_reply", %{"content" => content, "reply_to_id" => reply_to_id}, socket) do
    if String.trim(content) == "" do
      {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
    else
      reply_to_id = String.to_integer(reply_to_id)
      user = socket.assigns.current_user

      # Find parent reply
      parent_reply =
        socket.assigns.post_replies
        |> Map.values()
        |> List.flatten()
        |> Enum.find(&(&1.id == reply_to_id))

      reply_visibility =
        (parent_reply && parent_reply.visibility) || user.default_post_visibility || "public"

      case Social.create_timeline_post(
             user.id,
             content,
             visibility: reply_visibility,
             reply_to_id: reply_to_id
           ) do
        {:ok, _new_reply} ->
          # Increment reply count
          Social.increment_reply_count(reply_to_id)

          # Find the root post
          root_post =
            socket.assigns.posts
            |> Enum.find(fn post ->
              Map.get(socket.assigns.post_replies, post.id, [])
              |> Enum.any?(&(&1.id == reply_to_id))
            end)

          # Reload replies for the root post
          if root_post do
            reloaded_replies =
              Social.get_direct_replies_for_posts([root_post.id],
                user_id: user.id,
                limit_per_post: 3
              )

            updated_post_replies = Map.merge(socket.assigns.post_replies, reloaded_replies)

            # Update root post reply count
            updated_posts =
              Enum.map(socket.assigns.posts, fn post ->
                if post.id == root_post.id do
                  %{post | reply_count: (post.reply_count || 0) + 1}
                else
                  post
                end
              end)

            {:noreply,
             socket
             |> assign(:posts, updated_posts)
             |> assign(:post_replies, updated_post_replies)
             |> assign(:reply_to_reply_id, nil)
             |> assign(:reply_content, "")
             |> put_flash(:info, "Reply posted!")}
          else
            {:noreply, put_flash(socket, :error, "Failed to post reply")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to post reply")}
      end
    end
  end

  defp add_remote_user_to_list(socket, handle) do
    case Elektrine.ActivityPub.FederationHelpers.follow_remote_user(
           socket.assigns.current_user.username,
           handle
         ) do
      {:ok, result} ->
        case Social.add_to_list(socket.assigns.list.id, %{remote_actor_id: result.remote_actor.id}) do
          {:ok, _} -> :ok
          {:error, _reason} -> :error
        end

      {:error, :already_following} ->
        # Already followed, just add to list
        [username, domain] = String.split(handle, "@")

        case Elektrine.ActivityPub.get_actor_by_username_and_domain(username, domain) do
          nil ->
            :error

          actor ->
            case Social.add_to_list(socket.assigns.list.id, %{remote_actor_id: actor.id}) do
              {:ok, _} -> :ok
              {:error, _reason} -> :error
            end
        end

      {:error, _reason} ->
        :error
    end
  end

  defp add_local_user_to_list(socket, username) do
    case Elektrine.Accounts.get_user_by_username(username) do
      nil ->
        :error

      user ->
        case Social.add_to_list(socket.assigns.list.id, %{user_id: user.id}) do
          {:ok, _} -> :ok
          {:error, _reason} -> :error
        end
    end
  end

  # Helper to make links clickable
  defp make_links_and_hashtags_clickable(text) when is_binary(text) do
    text
    |> make_content_safe_with_links()
    |> render_custom_emojis()
    |> preserve_line_breaks()
  end

  defp make_links_and_hashtags_clickable(_), do: ""

  # Helper to update counts in either posts or replies
  defp update_message_count(posts, post_replies, message_id, field, delta) do
    # Try to update in posts
    updated_posts =
      Enum.map(posts, fn post ->
        if post.id == message_id do
          current_value = Map.get(post, field, 0)
          Map.put(post, field, max(0, current_value + delta))
        else
          post
        end
      end)

    # Try to update in replies
    updated_replies =
      Enum.into(post_replies, %{}, fn {post_id, replies} ->
        updated_reply_list =
          Enum.map(replies, fn reply ->
            if reply.id == message_id do
              current_value = Map.get(reply, field, 0)
              Map.put(reply, field, max(0, current_value + delta))
            else
              reply
            end
          end)

        {post_id, updated_reply_list}
      end)

    {updated_posts, updated_replies}
  end
end
