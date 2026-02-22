defmodule ElektrineWeb.ProfileLive.Show do
  use ElektrineWeb, :live_view
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Profile.Containers
  import ElektrineWeb.Components.User.VerificationBadge
  import ElektrineWeb.HtmlHelpers
  alias Elektrine.{Accounts, Messaging, Profiles, Social}
  @impl true
  def mount(%{"handle" => handle}, session, socket) do
    if !String.valid?(handle) or String.length(handle) > 100 or handle =~ ~r/[\x00-\x1f]/ do
      {:ok,
       socket
       |> assign(:page_title, "Not Found")
       |> assign(:user, nil)
       |> assign(:profile, nil)
       |> assign(:is_private, false)
       |> assign(:not_found, true)}
    else
      mount_with_valid_handle(handle, session, socket)
    end
  end

  defp mount_with_valid_handle(handle, session, socket) do
    user = Accounts.get_user_by_username_or_handle(handle)

    user =
      if user do
        Elektrine.Repo.preload(user, :profile)
      else
        nil
      end

    if user do
      current_user = socket.assigns[:current_user]

      viewer_id =
        if current_user do
          current_user.id
        else
          nil
        end

      can_view =
        if viewer_id do
          case Elektrine.Privacy.can_view_profile?(viewer_id, user.id) do
            {:ok, :allowed} -> true
            {:error, _} -> false
          end
        else
          user.profile_visibility == "public"
        end

      if can_view do
        profile =
          case Profiles.get_user_profile(user.id) do
            nil ->
              case Profiles.upsert_user_profile(user.id, %{
                     display_name: user.handle || user.username
                   }) do
                {:ok, prof} -> prof
                _ -> nil
              end

            prof ->
              prof
          end

        if connected?(socket) do
          viewer_user_id = current_user && current_user.id
          viewer_session_id = session["_csrf_token"]
          {ip_address, user_agent, referer} = get_connection_metadata(socket)

          Profiles.track_profile_view(user.id,
            viewer_user_id: viewer_user_id,
            viewer_session_id: viewer_session_id,
            ip_address: ip_address,
            user_agent: user_agent,
            referer: referer
          )
        end

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:follows")
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}:profile")
          send(self(), {:load_profile_data, user.id, profile})
        end

        links =
          if profile && match?([_ | _], profile.links) do
            profile.links
          else
            [
              %{
                title: "Contact",
                url: "mailto:#{user.username}@z.org",
                description: "Send me an email",
                platform: "email"
              }
            ]
          end

        is_custom =
          profile != nil &&
            (profile.links != nil || profile.description != nil || profile.background_url != nil)

        user_number = Accounts.get_user_number(user)

        {:ok,
         socket
         |> assign(
           :page_title,
           (profile && profile.page_title) || "#{user.handle || user.username} • Elektrine"
         )
         |> assign(:user, user)
         |> assign(:user_number, user_number)
         |> assign(:profile, profile)
         |> assign(:user_badges, [])
         |> assign(:follower_count, 0)
         |> assign(:following_count, 0)
         |> assign(:is_following, false)
         |> assign(:friend_status, %{
           are_friends: false,
           pending_request: false,
           sent_request: false
         })
         |> assign(:discord_data, nil)
         |> assign(:links, links)
         |> assign(:is_custom, is_custom)
         |> assign(:show_followers, false)
         |> assign(:show_following, false)
         |> assign(:followers_list, [])
         |> assign(:following_list, [])
         |> assign(:user_timeline_posts, [])
         |> assign(:pinned_posts, [])
         |> assign(:user_discussion_posts, [])
         |> assign(:show_report_modal, false)
         |> assign(:report_modal_type, nil)
         |> assign(:report_modal_id, nil)
         |> assign(:show_share_modal, false)
         |> assign(:profile_url, "https://#{user.handle}.z.org")
         |> assign(:base_url, "")
         |> assign(:show_timeline_drawer, false)
         |> assign(:show_image_modal, false)
         |> assign(:modal_image_url, nil)
         |> assign(:modal_images, [])
         |> assign(:modal_image_index, 0)
         |> assign(:modal_post, nil)
         |> assign(:loading_profile, true), layout: false}
      else
        {:ok,
         socket
         |> assign(:page_title, "#{user.handle || user.username} • Elektrine")
         |> assign(:user, user)
         |> assign(:profile, nil)
         |> assign(:is_private, true)
         |> assign(:current_user, current_user), layout: false}
      end
    else
      {:ok,
       socket
       |> assign(:page_title, "Not Found")
       |> assign(:user, nil)
       |> assign(:profile, nil)
       |> assign(:is_private, false)
       |> assign(:not_found, true)}
    end
  end

  @impl true
  def handle_event("toggle_follow", _params, socket) do
    current_user = socket.assigns[:current_user]
    profile_user = socket.assigns.user

    if current_user do
      is_currently_following = socket.assigns.is_following

      {new_is_following, new_follower_count} =
        if is_currently_following do
          Profiles.unfollow_user(current_user.id, profile_user.id)
          count = Profiles.get_follower_count(profile_user.id)

          Phoenix.PubSub.broadcast_from(
            Elektrine.PubSub,
            self(),
            "user:#{profile_user.id}:follows",
            {:follower_removed, current_user.id}
          )

          {false, count}
        else
          case Profiles.follow_user(current_user.id, profile_user.id) do
            {:ok, _follow} ->
              count = Profiles.get_follower_count(profile_user.id)

              Phoenix.PubSub.broadcast_from(
                Elektrine.PubSub,
                self(),
                "user:#{profile_user.id}:follows",
                {:follower_added, current_user.id}
              )

              {true, count}

            {:error, _} ->
              {is_currently_following, socket.assigns.follower_count}
          end
        end

      new_assigns = %{is_following: new_is_following, follower_count: new_follower_count}

      flash_message =
        if new_is_following != is_currently_following do
          if new_is_following do
            "Following #{profile_user.handle || profile_user.username}"
          else
            "Unfollowed #{profile_user.handle || profile_user.username}"
          end
        else
          nil
        end

      updated_socket =
        socket
        |> Phoenix.Component.assign(new_assigns)
        |> then(fn s ->
          if flash_message do
            put_flash(s, :info, flash_message)
          else
            s
          end
        end)

      Process.sleep(10)
      {:noreply, updated_socket}
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("show_followers", _params, socket) do
    followers = Profiles.get_followers(socket.assigns.user.id, limit: 50)

    {:noreply,
     socket
     |> assign(:show_followers, true)
     |> assign(:show_following, false)
     |> assign(:followers_list, followers)}
  end

  @impl true
  def handle_event("show_following", _params, socket) do
    following = Profiles.get_following(socket.assigns.user.id, limit: 50)

    {:noreply,
     socket
     |> assign(:show_following, true)
     |> assign(:show_followers, false)
     |> assign(:following_list, following)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:show_followers, false) |> assign(:show_following, false)}
  end

  def handle_event("unfollow_remote", %{"remote-actor-id" => remote_actor_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      case Profiles.unfollow_remote_actor(current_user.id, String.to_integer(remote_actor_id)) do
        {:ok, :unfollowed} ->
          following = Profiles.get_following(current_user.id, limit: 50)
          following_count = Profiles.get_following_count(current_user.id)

          {:noreply,
           socket
           |> assign(:following_list, following)
           |> assign(:following_count, following_count)
           |> put_flash(:info, "Unfollowed remote user")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to unfollow")}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  def handle_event("unfollow_local", %{"followed-id" => followed_id}, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      Profiles.unfollow_user(current_user.id, String.to_integer(followed_id))
      following = Profiles.get_following(current_user.id, limit: 50)
      following_count = Profiles.get_following_count(current_user.id)

      {:noreply,
       socket
       |> assign(:following_list, following)
       |> assign(:following_count, following_count)
       |> put_flash(:info, "Unfollowed user")}
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("send_friend_request", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns[:current_user]
    target_user_id = String.to_integer(user_id)

    if current_user do
      case Elektrine.Friends.send_friend_request(current_user.id, target_user_id) do
        {:ok, _request} ->
          friend_status =
            Elektrine.Friends.get_relationship_status(current_user.id, target_user_id)

          {:noreply,
           socket
           |> assign(:friend_status, friend_status)
           |> put_flash(:info, "Friend request sent")}

        {:error, :request_already_exists} ->
          {:noreply, put_flash(socket, :error, "A friend request already exists with this user")}

        {:error, reason} ->
          error_message = Elektrine.Privacy.privacy_error_message(reason)
          {:noreply, put_flash(socket, :error, error_message)}
      end
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("accept_friend_request", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns[:current_user]
    requester_id = String.to_integer(user_id)

    case socket.assigns.friend_status.pending_request do
      %{id: request_id} ->
        case Elektrine.Friends.accept_friend_request(request_id, current_user.id) do
          {:ok, _} ->
            friend_status =
              Elektrine.Friends.get_relationship_status(current_user.id, requester_id)

            {:noreply, assign(socket, :friend_status, friend_status)}

          {:error, :privacy_settings_changed} ->
            friend_status =
              Elektrine.Friends.get_relationship_status(current_user.id, requester_id)

            {:noreply,
             socket
             |> assign(:friend_status, friend_status)
             |> put_flash(
               :error,
               Elektrine.Privacy.privacy_error_message(:privacy_settings_changed)
             )}

          {:error, reason} ->
            error_message = Elektrine.Privacy.privacy_error_message(reason)
            {:noreply, put_flash(socket, :error, error_message)}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Request not found")}
    end
  end

  @impl true
  def handle_event("cancel_friend_request", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns[:current_user]
    target_user_id = String.to_integer(user_id)
    sent_requests = Elektrine.Friends.list_sent_requests(current_user.id)
    request = Enum.find(sent_requests, fn r -> r.recipient_id == target_user_id end)

    case request do
      nil ->
        {:noreply, put_flash(socket, :error, "Request not found")}

      request ->
        case Elektrine.Friends.cancel_friend_request(request.id, current_user.id) do
          {:ok, _} ->
            friend_status =
              Elektrine.Friends.get_relationship_status(current_user.id, target_user_id)

            {:noreply, assign(socket, :friend_status, friend_status)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to cancel request")}
        end
    end
  end

  @impl true
  def handle_event("unfriend_user", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns[:current_user]
    target_user_id = String.to_integer(user_id)

    case Elektrine.Friends.unfriend(current_user.id, target_user_id) do
      {:ok, _} ->
        friend_status = Elektrine.Friends.get_relationship_status(current_user.id, target_user_id)
        {:noreply, assign(socket, :friend_status, friend_status)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove friend")}
    end
  end

  @impl true
  def handle_event("show_report_modal", %{"type" => type, "id" => id}, socket) do
    if socket.assigns[:current_user] do
      {:noreply,
       socket
       |> assign(:show_report_modal, true)
       |> assign(:report_modal_type, type)
       |> assign(:report_modal_id, String.to_integer(id))}
    else
      {:noreply, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_modal_type, nil)
     |> assign(:report_modal_id, nil)}
  end

  @impl true
  def handle_event("show_share_modal", _params, socket) do
    {:noreply, assign(socket, :show_share_modal, true)}
  end

  @impl true
  def handle_event("close_share_modal", _params, socket) do
    {:noreply, assign(socket, :show_share_modal, false)}
  end

  @impl true
  def handle_event("toggle_timeline_drawer", _params, socket) do
    {:noreply, assign(socket, :show_timeline_drawer, !socket.assigns.show_timeline_drawer)}
  end

  @impl true
  def handle_event("close_timeline_drawer", _params, socket) do
    {:noreply, assign(socket, :show_timeline_drawer, false)}
  end

  @impl true
  def handle_event("copy_profile_url", _params, socket) do
    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: socket.assigns.profile_url})
     |> put_flash(:info, "Profile link copied to clipboard!")}
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = params["url"] || Enum.at(images, index_int, List.first(images))

    modal_post =
      if params["post_id"] do
        post_id = String.to_integer(params["post_id"])
        posts = socket.assigns.user_timeline_posts ++ socket.assigns.pinned_posts
        Enum.find(posts, fn post -> post.id == post_id end)
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, index_int)
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

  @impl true
  def handle_info({:report_submitted, _type, _id}, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_modal_type, nil)
     |> assign(:report_modal_id, nil)
     |> put_flash(
       :info,
       "Report submitted successfully. Our moderation team will review it shortly."
     )}
  end

  @impl true
  def handle_info({:follower_added, _user_id}, socket) do
    {:noreply, update(socket, :follower_count, &(&1 + 1))}
  end

  @impl true
  def handle_info({:follower_removed, _user_id}, socket) do
    {:noreply, update(socket, :follower_count, &(&1 - 1))}
  end

  @impl true
  def handle_info({:new_follower, %{follower_id: _follower_id}}, socket) do
    {:noreply, update(socket, :follower_count, &(&1 + 1))}
  end

  @impl true
  def handle_info({:notification_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :notification_count, new_count)}
  end

  @impl true
  def handle_info({:profile_updated, _user_id}, socket) do
    profile = Profiles.get_user_profile(socket.assigns.user.id)
    {:noreply, assign(socket, :profile, profile)}
  end

  @impl true
  def handle_info({:load_profile_data, user_id, profile}, socket) do
    current_user = socket.assigns[:current_user]

    viewer_id =
      if current_user do
        current_user.id
      else
        nil
      end

    posts_task =
      Task.async(fn ->
        {Social.get_user_timeline_posts(user_id, limit: 5, viewer_id: viewer_id),
         Social.get_pinned_posts(user_id, viewer_id: viewer_id),
         Messaging.get_user_discussion_posts(user_id, limit: 5)}
      end)

    stats_task =
      Task.async(fn ->
        {Profiles.get_follower_count(user_id), Profiles.get_following_count(user_id)}
      end)

    relationship_task =
      Task.async(fn ->
        if current_user && current_user.id != user_id do
          {Profiles.following?(current_user.id, user_id),
           Elektrine.Friends.get_relationship_status(current_user.id, user_id)}
        else
          {false, %{are_friends: false, pending_request: false, sent_request: false}}
        end
      end)

    badges_task = Task.async(fn -> Profiles.list_visible_user_badges(user_id) end)

    discord_task =
      Task.async(fn ->
        if profile && profile.show_discord_presence && profile.discord_user_id do
          Elektrine.Discord.get_user_presence(profile.discord_user_id)
        else
          nil
        end
      end)

    {timeline_posts, pinned_posts, discussion_posts} = Task.await(posts_task, 10_000)
    {follower_count, following_count} = Task.await(stats_task, 5000)
    {is_following, friend_status} = Task.await(relationship_task, 5000)
    user_badges = Task.await(badges_task, 5000)
    discord_data = Task.await(discord_task, 5000)

    {:noreply,
     socket
     |> assign(:user_timeline_posts, timeline_posts)
     |> assign(:pinned_posts, pinned_posts)
     |> assign(:user_discussion_posts, discussion_posts)
     |> assign(:follower_count, follower_count)
     |> assign(:following_count, following_count)
     |> assign(:is_following, is_following)
     |> assign(:friend_status, friend_status)
     |> assign(:user_badges, user_badges)
     |> assign(:discord_data, discord_data)
     |> assign(:loading_profile, false)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp hex_to_rgb("#" <> hex) do
    {r, _} = Integer.parse(String.slice(hex, 0, 2), 16)
    {g, _} = Integer.parse(String.slice(hex, 2, 2), 16)
    {b, _} = Integer.parse(String.slice(hex, 4, 2), 16)
    {r, g, b}
  end

  defp hex_to_rgb(_hex) do
    {0, 0, 0}
  end

  defp lighten_color(hex, factor) do
    {r, g, b} = hex_to_rgb(hex)
    new_r = min(255, round(r + (255 - r) * factor))
    new_g = min(255, round(g + (255 - g) * factor))
    new_b = min(255, round(b + (255 - b) * factor))

    "#" <>
      String.pad_leading(Integer.to_string(new_r, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(new_g, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(new_b, 16), 2, "0")
  end

  defp light_color?(hex) do
    {r, g, b} = hex_to_rgb(hex)
    luminance = 0.2126 * (r / 255) + 0.7152 * (g / 255) + 0.0722 * (b / 255)
    luminance > 0.5
  end

  defp get_connection_metadata(socket) do
    ip_address =
      get_connect_params(socket)["remote_ip"] || get_connect_params(socket)["x_real_ip"] ||
        "unknown"

    user_agent =
      get_connect_params(socket)["user_agent"] || get_connect_params(socket)["_user_agent"] ||
        "unknown"

    referer =
      get_connect_params(socket)["referer"] || get_connect_params(socket)["_referer"] || nil

    {to_string(ip_address), to_string(user_agent), referer}
  end
end
