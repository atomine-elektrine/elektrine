defmodule ElektrineWeb.ProfileController do
  @moduledoc """
  Controller for user profile pages and profile-related JSON API endpoints.

  This controller serves two purposes:

  1. **Profile Page Rendering** (`show/2`)
     Renders user profile pages as static HTML. Used for:
     - Subdomain access (e.g., username.z.org) where LiveView websockets don't work
     - SEO-friendly profile pages
     - Fallback when LiveView is unavailable

  2. **Profile JSON API** (followers, following, follow actions, friend actions)
     Provides JSON endpoints for profile interactions, used by:
     - Static profile pages via JavaScript (profile_static.js)
     - Any client that needs profile data without LiveView

  ## Routes

  ### Page Routes (browser pipeline)
      GET /:handle - Show user profile page

  ### API Routes (browser_api pipeline)
      GET  /profiles/:handle/followers         - Get user's followers list
      GET  /profiles/:handle/following         - Get user's following list
      POST /profiles/:handle/follow            - Follow a user
      DELETE /profiles/:handle/follow          - Unfollow a user
      POST /profiles/:handle/friend-request    - Send friend request
      POST /profiles/:handle/friend-request/accept - Accept friend request
      DELETE /profiles/:handle/friend-request  - Cancel friend request
      DELETE /profiles/:handle/friend          - Remove friend
  """

  use ElektrineWeb, :controller
  alias Elektrine.{Accounts, Profiles, StaticSites, Social, Messaging, Friends}

  # Reserved usernames that conflict with routes
  @reserved_usernames [
    "admin",
    "api",
    "account",
    "email",
    "temp-mail",
    "siem",
    "search",
    "login",
    "register",
    "dev",
    "www",
    "support",
    "help",
    "about",
    "contact",
    "terms",
    "privacy",
    "blog",
    "docs",
    "status",
    "health",
    "ping",
    "test"
  ]

  def show(conn, params) do
    handle =
      Map.get(params, "handle") || conn.assigns[:subdomain_handle]

    if !is_binary(handle) or handle == "" do
      conn
      |> put_status(:not_found)
      |> put_view(html: ElektrineWeb.ErrorHTML)
      |> render(:"404")
    else
      # Only allow profiles in dev/test environment or on z.org/elektrine.com domains
      if Application.get_env(:elektrine, :environment) in [:dev, :test] or
           String.ends_with?(conn.host, "z.org") or
           String.ends_with?(conn.host, "elektrine.com") do
        # Check if handle is reserved
        if handle in @reserved_usernames do
          conn
          |> put_status(:not_found)
          |> put_view(html: ElektrineWeb.ErrorHTML)
          |> render(:"404")
        else
          case Profiles.get_profile_by_handle(handle) do
            nil ->
              # No custom profile, check if user exists for default profile
              case Accounts.get_user_by_handle(handle) do
                nil ->
                  conn
                  |> put_status(:not_found)
                  |> put_view(html: ElektrineWeb.ErrorHTML)
                  |> render(:"404")

                user ->
                  # Check profile visibility settings
                  current_user = conn.assigns[:current_user]

                  case Accounts.can_view_profile?(user, current_user) do
                    {:ok, :allowed} ->
                      # Show default profile - create minimal profile for view tracking
                      # Create or get profile just for view counting
                      {profile, conn} =
                        case Profiles.upsert_user_profile(user.id, %{display_name: user.username}) do
                          {:ok, prof} ->
                            if should_increment_view?(conn, prof.id) do
                              # Track profile view using the new accurate tracking system
                              viewer_user_id = if current_user, do: current_user.id, else: nil

                              Profiles.track_profile_view(user.id,
                                viewer_user_id: viewer_user_id,
                                ip_address: to_string(:inet_parse.ntoa(conn.remote_ip)),
                                user_agent: get_req_header(conn, "user-agent") |> List.first(),
                                referer: get_req_header(conn, "referer") |> List.first()
                              )

                              updated_conn = record_profile_view(conn, prof.id)
                              updated_profile = Profiles.get_user_profile(user.id)
                              {updated_profile, updated_conn}
                            else
                              {prof, conn}
                            end

                          _ ->
                            {nil, conn}
                        end

                      render_default_profile(conn, user, profile)

                    {:error, :privacy_restriction} ->
                      conn
                      |> put_status(:forbidden)
                      |> put_view(html: ElektrineWeb.ErrorHTML)
                      |> render(:"403")
                  end
              end

            profile ->
              # Check profile visibility settings
              current_user = conn.assigns[:current_user]
              user = Accounts.get_user!(profile.user_id)

              case Accounts.can_view_profile?(user, current_user) do
                {:ok, :allowed} ->
                  # Show custom profile and increment view count (if unique)
                  if should_increment_view?(conn, profile.id) do
                    # Track profile view using the new accurate tracking system
                    viewer_user_id = if current_user, do: current_user.id, else: nil

                    Profiles.track_profile_view(profile.user_id,
                      viewer_user_id: viewer_user_id,
                      ip_address: to_string(:inet_parse.ntoa(conn.remote_ip)),
                      user_agent: get_req_header(conn, "user-agent") |> List.first(),
                      referer: get_req_header(conn, "referer") |> List.first()
                    )

                    # Record this view in session
                    conn = record_profile_view(conn, profile.id)

                    # Reload profile to get updated view count
                    updated_profile = Profiles.get_profile_by_handle(handle)

                    render_custom_profile(conn, updated_profile)
                  else
                    render_custom_profile(conn, profile)
                  end

                {:error, :privacy_restriction} ->
                  conn
                  |> put_status(:forbidden)
                  |> put_view(html: ElektrineWeb.ErrorHTML)
                  |> render(:"403")
              end
          end
        end
      else
        # Not z.org domain - 404
        conn
        |> put_status(:not_found)
        |> put_view(html: ElektrineWeb.ErrorHTML)
        |> render(:"404")
      end
    end
  end

  defp render_default_profile(conn, user, profile) do
    # Default profile for users who haven't customized
    default_links = [
      %{
        title: "Contact",
        url: "mailto:#{user.username}@z.org",
        description: "Send me an email",
        icon: "hero-at-symbol",
        platform: "email"
      }
    ]

    # Get Discord presence if enabled (even for default profiles)
    discord_data =
      if profile && profile.show_discord_presence && profile.discord_user_id do
        Elektrine.Discord.get_user_presence(profile.discord_user_id)
      else
        nil
      end

    # Get follow stats
    follower_count = Profiles.get_follower_count(user.id)
    following_count = Profiles.get_following_count(user.id)

    # Check if current user is following this profile
    current_user = conn.assigns[:current_user]

    is_following =
      if current_user && current_user.id != user.id do
        Profiles.following?(current_user.id, user.id)
      else
        false
      end

    profile_context = build_profile_context(user, current_user)

    conn
    |> assign(:user, user)
    |> assign(:profile, profile)
    |> assign(:links, default_links)
    |> assign(:is_custom, false)
    |> assign(:discord_data, discord_data)
    |> assign(:follower_count, follower_count)
    |> assign(:following_count, following_count)
    |> assign(:is_following, is_following)
    |> assign(:friend_status, profile_context.friend_status)
    |> assign(:user_timeline_posts, profile_context.user_timeline_posts)
    |> assign(:pinned_posts, profile_context.pinned_posts)
    |> assign(:user_discussion_posts, profile_context.user_discussion_posts)
    |> assign(:user_number, profile_context.user_number)
    |> assign(:user_badges, profile_context.user_badges)
    |> assign_profile_defaults(user)
    |> put_root_layout(html: {ElektrineWeb.Layouts, :profile})
    |> render(:show, layout: false)
  end

  defp render_custom_profile(conn, profile) do
    # Check if profile is in static mode
    if profile.profile_mode == "static" do
      render_static_site(conn, profile)
    else
      render_builder_profile(conn, profile)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp render_static_site(conn, profile) do
    # Serve static site index.html
    case StaticSites.get_file(profile.user_id, "index.html") do
      nil ->
        # No index.html, fall back to builder profile
        render_builder_profile(conn, profile)

      file ->
        case StaticSites.get_file_content(file) do
          {:ok, content} ->
            conn
            |> put_resp_content_type("text/html")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> send_resp(200, content)

          {:error, _} ->
            # Error fetching content, fall back to builder
            render_builder_profile(conn, profile)
        end
    end
  end

  defp render_builder_profile(conn, profile) do
    # Get Discord presence if enabled
    discord_data =
      if profile.show_discord_presence && profile.discord_user_id do
        Elektrine.Discord.get_user_presence(profile.discord_user_id)
      else
        nil
      end

    # Get follow stats
    follower_count = Profiles.get_follower_count(profile.user_id)
    following_count = Profiles.get_following_count(profile.user_id)

    # Check if current user is following this profile
    current_user = conn.assigns[:current_user]

    is_following =
      if current_user && current_user.id != profile.user_id do
        Profiles.following?(current_user.id, profile.user_id)
      else
        false
      end

    profile_context = build_profile_context(profile.user, current_user)

    conn
    |> assign(:user, profile.user)
    |> assign(:profile, profile)
    |> assign(:links, profile.links)
    |> assign(:is_custom, true)
    |> assign(:discord_data, discord_data)
    |> assign(:follower_count, follower_count)
    |> assign(:following_count, following_count)
    |> assign(:is_following, is_following)
    |> assign(:friend_status, profile_context.friend_status)
    |> assign(:user_timeline_posts, profile_context.user_timeline_posts)
    |> assign(:pinned_posts, profile_context.pinned_posts)
    |> assign(:user_discussion_posts, profile_context.user_discussion_posts)
    |> assign(:user_number, profile_context.user_number)
    |> assign(:user_badges, profile_context.user_badges)
    |> assign_profile_defaults(profile.user)
    |> put_root_layout(html: {ElektrineWeb.Layouts, :profile})
    |> render(:show, layout: false)
  end

  def followers(conn, %{"handle" => handle}) do
    current_user = conn.assigns[:current_user]

    case Accounts.get_user_by_username_or_handle(handle) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        case Accounts.can_view_profile?(user, current_user) do
          {:ok, :allowed} ->
            followers = Profiles.get_followers(user.id, limit: 50)

            conn
            |> put_status(:ok)
            |> json(%{followers: Enum.map(followers, &format_follow_entry/1)})

          {:error, :privacy_restriction} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Profile is private"})
        end
    end
  end

  def following(conn, %{"handle" => handle}) do
    current_user = conn.assigns[:current_user]

    case Accounts.get_user_by_username_or_handle(handle) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        case Accounts.can_view_profile?(user, current_user) do
          {:ok, :allowed} ->
            following = Profiles.get_following(user.id, limit: 50)

            conn
            |> put_status(:ok)
            |> json(%{following: Enum.map(following, &format_follow_entry/1)})

          {:error, :privacy_restriction} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Profile is private"})
        end
    end
  end

  def follow(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         {:ok, _follow} <- Profiles.follow_user(current_user.id, user.id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "followed"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def unfollow(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle) do
      Profiles.unfollow_user(current_user.id, user.id)

      conn
      |> put_status(:ok)
      |> json(%{status: "unfollowed"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def send_friend_request(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         {:ok, _request} <- Elektrine.Friends.send_friend_request(current_user.id, user.id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "requested"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  def accept_friend_request(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         request when not is_nil(request) <-
           Elektrine.Friends.get_friend_request(current_user.id, user.id),
         {:ok, _request} <- Elektrine.Friends.accept_friend_request(request.id, current_user.id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "accepted"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Friend request not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def cancel_friend_request(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         request when not is_nil(request) <-
           Elektrine.Friends.get_friend_request(current_user.id, user.id),
         {:ok, _request} <- Elektrine.Friends.cancel_friend_request(request.id, current_user.id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "cancelled"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Friend request not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def unfriend(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         {:ok, _request} <- Elektrine.Friends.unfriend(current_user.id, user.id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "unfriended"})
    else
      {:error, :unauthenticated, _conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp assign_profile_defaults(conn, user) do
    # Subdomain URLs use the user's handle
    profile_url = "https://#{user.handle}.z.org"
    # Base URL for absolute links - ensures navigation goes to main domain, not subdomain
    base_url = get_base_url(conn)

    conn
    |> assign_if_missing(:profile_static, true)
    |> assign_if_missing(:current_user, conn.assigns[:current_user])
    |> assign_if_missing(:profile_url, profile_url)
    |> assign_if_missing(:base_url, base_url)
    |> assign_if_missing(:show_followers, false)
    |> assign_if_missing(:show_following, false)
    |> assign_if_missing(:followers_list, [])
    |> assign_if_missing(:following_list, [])
    |> assign_if_missing(:user_timeline_posts, [])
    |> assign_if_missing(:pinned_posts, [])
    |> assign_if_missing(:user_discussion_posts, [])
    |> assign_if_missing(:user_likes, %{})
    |> assign_if_missing(:show_report_modal, false)
    |> assign_if_missing(:report_modal_type, nil)
    |> assign_if_missing(:report_modal_id, nil)
    |> assign_if_missing(:show_share_modal, false)
    |> assign_if_missing(:show_timeline_drawer, false)
    |> assign_if_missing(:show_image_modal, false)
    |> assign_if_missing(:modal_image_url, nil)
    |> assign_if_missing(:modal_images, [])
    |> assign_if_missing(:modal_image_index, 0)
    |> assign_if_missing(:modal_post, nil)
    |> assign_if_missing(:friend_status, nil)
    |> assign_if_missing(:user_badges, [])
    |> assign_if_missing(:user_number, nil)
    |> assign_if_missing(:time_format, conn.assigns[:time_format] || "relative")
    |> assign_if_missing(:timezone, conn.assigns[:timezone] || "UTC")
    |> assign_if_missing(:is_private, false)
    |> assign_if_missing(:not_found, false)
    |> assign_if_missing(:loading_profile, false)
  end

  defp build_profile_context(user, current_user) do
    viewer_id = if current_user, do: current_user.id, else: nil

    %{
      user_timeline_posts:
        Social.get_user_timeline_posts(user.id, limit: 5, viewer_id: viewer_id),
      pinned_posts: Social.get_pinned_posts(user.id, viewer_id: viewer_id),
      user_discussion_posts: Messaging.get_user_discussion_posts(user.id, limit: 5),
      user_number: Accounts.get_user_number(user),
      user_badges: Profiles.list_visible_user_badges(user.id),
      friend_status:
        if current_user && current_user.id != user.id do
          Friends.get_relationship_status(current_user.id, user.id)
        else
          %{
            are_friends: false,
            pending_request: nil,
            you_follow_them: false,
            they_follow_you: false,
            mutual_follow: false
          }
        end
    }
  end

  defp assign_if_missing(conn, key, value) do
    if Map.has_key?(conn.assigns, key) do
      conn
    else
      assign(conn, key, value)
    end
  end

  # Get the base URL for absolute links.
  # On subdomains (e.g., username.z.org, username.elektrine.com), returns the main domain.
  # On main domain or localhost, returns empty string (relative URLs work fine).
  defp get_base_url(conn) do
    host = conn.host

    cond do
      # Subdomain pattern: username.z.org
      String.ends_with?(host, ".z.org") ->
        "https://z.org"

      # Subdomain pattern: username.elektrine.com
      String.ends_with?(host, ".elektrine.com") ->
        "https://elektrine.com"

      # Main domain or localhost - use relative URLs
      true ->
        ""
    end
  end

  defp require_current_user(conn) do
    case conn.assigns[:current_user] do
      nil ->
        {:error, :unauthenticated, conn}

      user ->
        {:ok, user}
    end
  end

  defp format_follow_entry(%{type: "local", user: user}) do
    %{
      type: "local",
      id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name,
      avatar_url: Elektrine.Uploads.avatar_url(user.avatar)
    }
  end

  defp format_follow_entry(%{type: "remote", remote_actor: actor}) do
    %{
      type: "remote",
      id: actor.id,
      username: actor.username,
      display_name: actor.display_name,
      domain: actor.domain,
      avatar_url: actor.avatar_url
    }
  end

  # Check if we should increment view count (prevent duplicates)
  defp should_increment_view?(conn, profile_id) do
    # Get visitor's IP address
    visitor_ip = get_visitor_ip(conn)

    # Check session for recent views
    recent_views = get_session(conn, :profile_views) || %{}
    last_view_time = Map.get(recent_views, "#{profile_id}_#{visitor_ip}")

    # Only count if not viewed in last 30 minutes
    if last_view_time do
      time_diff = System.system_time(:second) - last_view_time
      # 30 minutes
      time_diff > 1800
    else
      # First view
      true
    end
  end

  # Record a profile view in session
  defp record_profile_view(conn, profile_id) do
    visitor_ip = get_visitor_ip(conn)
    current_time = System.system_time(:second)

    recent_views = get_session(conn, :profile_views) || %{}
    updated_views = Map.put(recent_views, "#{profile_id}_#{visitor_ip}", current_time)

    put_session(conn, :profile_views, updated_views)
  end

  # Get visitor IP with proxy header support
  defp get_visitor_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded_ip | _] ->
        forwarded_ip |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    end
  end
end
