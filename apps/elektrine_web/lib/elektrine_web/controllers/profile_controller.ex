defmodule ElektrineWeb.ProfileController do
  @moduledoc """
  Controller for user profile pages and profile-related JSON API endpoints.

  This controller serves two purposes:

  1. **Profile Page Rendering** (`show/2`)
     Renders user profile pages as static HTML. Used for:
     - Subdomain access (e.g., username.example.com) where LiveView websockets don't work
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

  alias Elektrine.{
    AccountIdentifiers,
    Accounts,
    Domains,
    Friends,
    Messaging,
    Profiles,
    RuntimeEnv,
    StaticSites
  }

  alias Elektrine.Accounts.User

  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Platform.Integrations

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

    case valid_profile_handle?(handle) do
      false ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ElektrineWeb.ErrorHTML)
        |> render(:"404")

      true ->
        # Only allow profiles in dev/test environment or on configured profile domains
        if RuntimeEnv.dev_or_test?() or
             allowed_profile_host?(conn.host) do
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
                          case Profiles.upsert_user_profile(user.id, %{
                                 display_name: user.username
                               }) do
                            {:ok, prof} ->
                              viewer_user_id = if current_user, do: current_user.id, else: nil
                              {updated_conn, visitor_id} = ensure_profile_site_visitor_id(conn)

                              Profiles.track_profile_site_visit(user.id,
                                viewer_user_id: viewer_user_id,
                                visitor_id: visitor_id,
                                ip_address: ClientIP.client_ip(conn),
                                user_agent: get_req_header(conn, "user-agent") |> List.first(),
                                referer: get_req_header(conn, "referer") |> List.first(),
                                request_host: conn.host,
                                request_path: conn.request_path
                              )

                              if should_increment_view?(updated_conn, prof.id) do
                                # Track profile view using the deduped profile counter.
                                Profiles.track_profile_view(user.id,
                                  viewer_user_id: viewer_user_id,
                                  viewer_session_id: visitor_id,
                                  ip_address: ClientIP.client_ip(conn),
                                  user_agent: get_req_header(conn, "user-agent") |> List.first(),
                                  referer: get_req_header(conn, "referer") |> List.first()
                                )

                                updated_conn = record_profile_view(updated_conn, prof.id)
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
                    viewer_user_id = if current_user, do: current_user.id, else: nil
                    {conn, visitor_id} = ensure_profile_site_visitor_id(conn)

                    Profiles.track_profile_site_visit(profile.user_id,
                      viewer_user_id: viewer_user_id,
                      visitor_id: visitor_id,
                      ip_address: ClientIP.client_ip(conn),
                      user_agent: get_req_header(conn, "user-agent") |> List.first(),
                      referer: get_req_header(conn, "referer") |> List.first(),
                      request_host: conn.host,
                      request_path: conn.request_path
                    )

                    if should_increment_view?(conn, profile.id) do
                      # Track profile view using the deduped profile counter.
                      Profiles.track_profile_view(profile.user_id,
                        viewer_user_id: viewer_user_id,
                        viewer_session_id: visitor_id,
                        ip_address: ClientIP.client_ip(conn),
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
          # Not an allowed profile domain - 404
          conn
          |> put_status(:not_found)
          |> put_view(html: ElektrineWeb.ErrorHTML)
          |> render(:"404")
        end
    end
  end

  defp valid_profile_handle?(handle) when is_binary(handle) do
    byte_size(handle) <= 100 and String.valid?(handle) and
      not String.contains?(handle, ["/", "\0", "\r", "\n", "\t"])
  end

  defp valid_profile_handle?(_), do: false

  defp render_default_profile(conn, user, profile) do
    # Default profile for users who haven't customized
    default_links = [
      %{
        title: "Contact",
        url: AccountIdentifiers.public_contact_mailto(user),
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
    # Custom profile domains should always resolve to the user's profile page.
    # Static-site mode remains available on built-in profile hosts/subdomains.
    if profile.profile_mode == "static" and not is_binary(conn.assigns[:profile_custom_domain]) do
      render_static_site(conn, profile)
    else
      render_builder_profile(conn, profile)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp render_static_site(conn, profile) do
    user = Accounts.get_user!(profile.user_id)
    handle = conn.assigns[:subdomain_handle] || user.handle || user.username

    # Serve static site index.html
    if User.built_in_subdomain_hosted_by_platform?(user) and
         Elektrine.Domains.app_host?(conn.host) and Elektrine.Strings.present?(handle) and
         conn.assigns[:subdomain_handle] != handle do
      redirect(conn, external: Elektrine.Domains.profile_url_for_handle(handle, conn.host))
    else
      case StaticSites.get_file(profile.user_id, "index.html") do
        nil ->
          # No index.html, fall back to builder profile
          render_builder_profile(conn, profile)

        file ->
          case StaticSites.get_file_content(file) do
            {:ok, content} ->
              conn
              |> put_resp_content_type("text/html")
              |> ElektrineWeb.Plugs.StaticSitePlug.put_static_html_headers()
              |> send_resp(200, content)

            {:error, _} ->
              # Error fetching content, fall back to builder
              render_builder_profile(conn, profile)
          end
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
      respond_follow_action(conn, handle, :ok, :followed)
    else
      {:error, :unauthenticated, _conn} ->
        respond_follow_action(conn, handle, :unauthorized, {:error, "Authentication required"})

      nil ->
        respond_follow_action(conn, handle, :not_found, {:error, "User not found"})

      {:error, reason} ->
        respond_follow_action(conn, handle, :unprocessable_entity, {:error, inspect(reason)})
    end
  end

  def unfollow(conn, %{"handle" => handle}) do
    with {:ok, current_user} <- require_current_user(conn),
         user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle) do
      Profiles.unfollow_user(current_user.id, user.id)

      respond_follow_action(conn, handle, :ok, :unfollowed)
    else
      {:error, :unauthenticated, _conn} ->
        respond_follow_action(conn, handle, :unauthorized, {:error, "Authentication required"})

      nil ->
        respond_follow_action(conn, handle, :not_found, {:error, "User not found"})

      {:error, reason} ->
        respond_follow_action(conn, handle, :unprocessable_entity, {:error, inspect(reason)})
    end
  end

  defp respond_follow_action(conn, handle, status, result) do
    if browser_follow_request?(conn) do
      conn = fetch_flash(conn, [])

      case result do
        :followed ->
          conn
          |> put_flash(:info, "Followed @#{handle}")
          |> redirect(to: profile_return_path(conn, handle))

        :unfollowed ->
          conn
          |> put_flash(:info, "Unfollowed @#{handle}")
          |> redirect(to: profile_return_path(conn, handle))

        {:error, "Authentication required"} ->
          conn
          |> put_session(:user_return_to, profile_return_path(conn, handle))
          |> redirect(to: Elektrine.Paths.login_path())

        {:error, message} ->
          conn
          |> put_flash(:error, message)
          |> redirect(to: profile_return_path(conn, handle))
      end
    else
      case result do
        :followed ->
          conn
          |> put_status(status)
          |> json(%{status: "followed"})

        :unfollowed ->
          conn
          |> put_status(status)
          |> json(%{status: "unfollowed"})

        {:error, message} ->
          conn
          |> put_status(status)
          |> json(%{error: message})
      end
    end
  end

  defp browser_follow_request?(conn) do
    headers =
      [get_req_header(conn, "accept"), get_req_header(conn, "content-type")] |> List.flatten()

    Enum.all?(headers, fn header -> not String.contains?(header, "application/json") end)
  end

  defp profile_return_path(conn, handle) do
    cond do
      is_binary(conn.assigns[:profile_custom_domain]) -> "/"
      is_binary(conn.assigns[:subdomain_handle]) and conn.assigns[:subdomain_handle] != "" -> "/"
      true -> "/#{handle}"
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
    local_handle = user.handle || user.username
    custom_profile_domain = conn.assigns[:profile_custom_domain]

    profile_host_domain =
      custom_profile_domain || Domains.profile_base_domain_for_host(conn.host) ||
        Domains.primary_profile_domain()

    profile_navigation_domain =
      if custom_profile_domain, do: Domains.primary_profile_domain(), else: profile_host_domain

    profile_url =
      if custom_profile_domain,
        do: "https://#{custom_profile_domain}",
        else: Domains.profile_url_for_handle(local_handle, conn.host)

    # Base URL for absolute links - ensures navigation goes to main domain, not subdomain
    base_url = get_base_url(conn)

    conn
    |> assign_if_missing(:profile_static, true)
    |> assign_if_missing(:current_user, conn.assigns[:current_user])
    |> assign_if_missing(:profile_host_domain, profile_host_domain)
    |> assign_if_missing(:profile_navigation_domain, profile_navigation_domain)
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
        Integrations.profile_timeline_posts(user.id, limit: 5, viewer_id: viewer_id),
      pinned_posts: Integrations.profile_pinned_posts(user.id, viewer_id: viewer_id),
      user_discussion_posts:
        Messaging.get_user_discussion_posts(user.id, limit: 5, viewer_id: viewer_id),
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
  # On subdomains (e.g., username.example.com), returns the main domain.
  # On main domain or localhost, returns empty string (relative URLs work fine).
  defp get_base_url(conn) do
    host = String.downcase(conn.host || "")

    if is_binary(conn.assigns[:profile_custom_domain]) do
      "https://#{Domains.primary_profile_domain()}"
    else
      case Domains.profile_base_domain_for_host(host) do
        nil ->
          ""

        domain ->
          if host == domain or host == "www." <> domain do
            ""
          else
            "https://#{domain}"
          end
      end
    end
  end

  defp allowed_profile_host?(host) when is_binary(host) do
    not is_nil(Domains.profile_base_domain_for_host(host)) or
      match?(%{domain: _}, Domains.profile_custom_domain_for_host(host))
  end

  defp allowed_profile_host?(_), do: false

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
    recent_views = recent_profile_views(conn)
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

    updated_views =
      conn
      |> recent_profile_views()
      |> Map.put("#{profile_id}_#{visitor_ip}", current_time)
      |> prune_recent_profile_views(current_time)

    put_session(conn, :profile_views, updated_views)
  end

  defp recent_profile_views(conn) do
    case get_session(conn, :profile_views) do
      views when is_map(views) -> views
      _ -> %{}
    end
  end

  defp prune_recent_profile_views(views, current_time) do
    views
    |> Enum.filter(fn {_key, viewed_at} ->
      is_integer(viewed_at) and current_time - viewed_at <= 1800
    end)
    |> Enum.sort_by(fn {_key, viewed_at} -> viewed_at end, :desc)
    |> Enum.take(50)
    |> Map.new()
  end

  defp ensure_profile_site_visitor_id(conn) do
    case get_session(conn, :profile_site_visitor_id) do
      visitor_id when is_binary(visitor_id) and visitor_id != "" ->
        {conn, visitor_id}

      _ ->
        visitor_id = Ecto.UUID.generate()
        {put_session(conn, :profile_site_visitor_id, visitor_id), visitor_id}
    end
  end

  # Get visitor IP with proxy header support
  defp get_visitor_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end
end
