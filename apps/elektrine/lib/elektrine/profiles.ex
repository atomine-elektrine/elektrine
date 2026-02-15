defmodule Elektrine.Profiles do
  @moduledoc """
  The Profiles context for managing customizable user profile pages.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Profiles.{
    UserProfile,
    ProfileLink,
    ProfileWidget,
    UserBadge,
    Follow,
    ProfileView
  }

  alias Elektrine.Accounts.User

  @doc """
  Gets a user's profile page.
  """
  def get_user_profile(user_id) do
    links_query = from(l in ProfileLink, where: l.is_active == true, order_by: l.position)
    widgets_query = from(w in ProfileWidget, where: w.is_active == true, order_by: w.position)

    UserProfile
    |> where([p], p.user_id == ^user_id)
    |> preload(links: ^links_query, widgets: ^widgets_query)
    |> Repo.one()
  end

  @doc """
  Gets a profile by username.
  """
  def get_profile_by_username(username) do
    links_query = from(l in ProfileLink, where: l.is_active == true, order_by: l.position)
    widgets_query = from(w in ProfileWidget, where: w.is_active == true, order_by: w.position)

    UserProfile
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.username == ^username)
    |> where([p], p.is_public == true)
    |> preload([:user, links: ^links_query, widgets: ^widgets_query])
    |> Repo.one()
  end

  @doc """
  Gets a public user profile by the user's handle.
  Used for subdomain profile lookups (e.g., handle.z.org).
  """
  def get_profile_by_handle(handle) do
    links_query = from(l in ProfileLink, where: l.is_active == true, order_by: l.position)
    widgets_query = from(w in ProfileWidget, where: w.is_active == true, order_by: w.position)

    UserProfile
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.handle == ^handle)
    |> where([p], p.is_public == true)
    |> preload([:user, links: ^links_query, widgets: ^widgets_query])
    |> Repo.one()
  end

  @doc """
  Creates or updates a user's profile.
  """
  def upsert_user_profile(user_id, attrs) do
    case get_user_profile(user_id) do
      nil ->
        create_user_profile(user_id, attrs)

      profile ->
        update_user_profile(profile, attrs)
    end
  end

  @doc """
  Creates a profile.
  """
  def create_user_profile(user_id, attrs) do
    %UserProfile{}
    |> UserProfile.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Updates a profile.
  """
  def update_user_profile(profile, attrs) do
    result =
      profile
      |> UserProfile.changeset(attrs)
      |> Repo.update()

    # Broadcast profile update so profile show page can refresh
    case result do
      {:ok, updated_profile} ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{updated_profile.user_id}:profile",
          {:profile_updated, updated_profile.user_id}
        )

        # Federate profile update to ActivityPub
        Task.start(fn ->
          Elektrine.ActivityPub.Outbox.federate_profile_update(updated_profile.user_id)
        end)

        result

      _ ->
        result
    end
  end

  @doc """
  Creates a link for a profile.
  """
  def create_profile_link(profile_id, attrs) do
    %ProfileLink{}
    |> ProfileLink.changeset(Map.put(attrs, "profile_id", profile_id))
    |> Repo.insert()
  end

  @doc """
  Updates a link.
  """
  def update_profile_link(link, attrs) do
    link
    |> ProfileLink.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a link.
  """
  def delete_profile_link(link) do
    Repo.delete(link)
  end

  @doc """
  Tracks a profile view with deduplication.
  Only counts unique views per viewer within 24 hours.

  ## Options
  - :viewer_user_id - ID of logged-in viewer (optional)
  - :viewer_session_id - Session ID for anonymous viewers (optional)
  - :ip_address - IP address of viewer
  - :user_agent - User agent string
  - :referer - HTTP referer

  Returns {:ok, :tracked} if view was counted, {:ok, :duplicate} if skipped
  """
  def track_profile_view(profile_user_id, opts \\ []) do
    viewer_user_id = Keyword.get(opts, :viewer_user_id)
    viewer_session_id = Keyword.get(opts, :viewer_session_id)
    ip_address = Keyword.get(opts, :ip_address)
    user_agent = Keyword.get(opts, :user_agent)
    referer = Keyword.get(opts, :referer)

    # Don't track if viewer is the profile owner
    if viewer_user_id && viewer_user_id == profile_user_id do
      {:ok, :own_profile}
    else
      # Check if this viewer already viewed within last 24 hours
      twenty_four_hours_ago = DateTime.utc_now() |> DateTime.add(-24, :hour)

      duplicate =
        cond do
          viewer_user_id ->
            # Check by user ID
            from(pv in ProfileView,
              where:
                pv.profile_user_id == ^profile_user_id and
                  pv.viewer_user_id == ^viewer_user_id and
                  pv.inserted_at > ^twenty_four_hours_ago,
              limit: 1
            )
            |> Repo.one()

          is_binary(viewer_session_id) and viewer_session_id != "" ->
            # Check by session ID
            from(pv in ProfileView,
              where:
                pv.profile_user_id == ^profile_user_id and
                  pv.viewer_session_id == ^viewer_session_id and
                  pv.inserted_at > ^twenty_four_hours_ago,
              limit: 1
            )
            |> Repo.one()

          true ->
            nil
        end

      if duplicate do
        {:ok, :duplicate}
      else
        attrs = %{
          profile_user_id: profile_user_id,
          viewer_user_id: viewer_user_id,
          viewer_session_id: viewer_session_id,
          ip_address: ip_address,
          user_agent: user_agent,
          referer: referer
        }

        case %ProfileView{}
             |> ProfileView.changeset(attrs)
             |> Repo.insert() do
          {:ok, _view} ->
            # Successfully tracked new view, increment counter
            from(p in UserProfile, where: p.user_id == ^profile_user_id)
            |> Repo.update_all(inc: [page_views: 1])

            {:ok, :tracked}

          {:error, changeset} ->
            {:error, changeset}
        end
      end
    end
  end

  @doc """
  Gets total view count for a profile user.
  """
  def get_profile_view_count(user_id) do
    from(pv in ProfileView,
      where: pv.profile_user_id == ^user_id,
      select: count(pv.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets unique viewer count for a profile user.
  Counts unique authenticated users who viewed the profile.
  """
  def get_unique_viewer_count(user_id) do
    from(pv in ProfileView,
      where: pv.profile_user_id == ^user_id and not is_nil(pv.viewer_user_id),
      select: count(pv.viewer_user_id, :distinct)
    )
    |> Repo.one()
  end

  @doc """
  Gets view count for a specific time period.
  """
  def get_profile_views_since(user_id, since_datetime) do
    from(pv in ProfileView,
      where: pv.profile_user_id == ^user_id and pv.inserted_at > ^since_datetime,
      select: count(pv.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets recent profile viewers (last 50).
  """
  def get_recent_viewers(user_id, limit \\ 50) do
    from(pv in ProfileView,
      where: pv.profile_user_id == ^user_id and not is_nil(pv.viewer_user_id),
      join: u in User,
      on: u.id == pv.viewer_user_id,
      order_by: [desc: pv.inserted_at],
      limit: ^limit,
      distinct: pv.viewer_user_id,
      select: %{
        user_id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        viewed_at: pv.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets view statistics for a profile.
  """
  def get_profile_view_stats(user_id) do
    now = DateTime.utc_now()
    today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00])
    week_ago = DateTime.add(now, -7, :day)
    month_ago = DateTime.add(now, -30, :day)

    %{
      total_views: get_profile_view_count(user_id),
      unique_viewers: get_unique_viewer_count(user_id),
      views_today: get_profile_views_since(user_id, today_start),
      views_this_week: get_profile_views_since(user_id, week_ago),
      views_this_month: get_profile_views_since(user_id, month_ago)
    }
  end

  @doc """
  Gets top referrers for a profile.
  """
  def get_top_referrers(user_id, limit \\ 10) do
    from(pv in ProfileView,
      where: pv.profile_user_id == ^user_id and not is_nil(pv.referer),
      group_by: pv.referer,
      select: %{referer: pv.referer, count: count(pv.id)},
      order_by: [desc: count(pv.id)],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Gets daily view counts for the last N days.
  Returns data suitable for charting with all days included (zero-filled).
  """
  def get_daily_view_counts(user_id, days \\ 30) do
    start_date = Date.utc_today() |> Date.add(-days + 1)
    end_date = Date.utc_today()

    # Get actual view counts from database
    actual_views =
      from(pv in ProfileView,
        where:
          pv.profile_user_id == ^user_id and fragment("DATE(?)", pv.inserted_at) >= ^start_date,
        group_by: fragment("DATE(?)", pv.inserted_at),
        select: %{date: fragment("DATE(?)", pv.inserted_at), count: count(pv.id)}
      )
      |> Repo.all()
      |> Map.new(fn %{date: date, count: count} -> {date, count} end)

    # Generate all dates in range
    Date.range(start_date, end_date)
    |> Enum.map(fn date ->
      %{
        date: date,
        count: Map.get(actual_views, date, 0)
      }
    end)
  end

  @doc """
  Gets most clicked profile links.
  """
  def get_top_links(user_id, limit \\ 10) do
    profile = get_user_profile(user_id)

    if profile do
      from(l in ProfileLink,
        where: l.profile_id == ^profile.id,
        order_by: [desc: l.clicks],
        limit: ^limit,
        select: %{id: l.id, title: l.title, url: l.url, platform: l.platform, clicks: l.clicks}
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Gets viewer breakdown (authenticated vs anonymous).
  """
  def get_viewer_breakdown(user_id) do
    total = get_profile_view_count(user_id)

    authenticated =
      from(pv in ProfileView,
        where: pv.profile_user_id == ^user_id and not is_nil(pv.viewer_user_id),
        select: count(pv.id)
      )
      |> Repo.one()

    %{
      total: total,
      authenticated: authenticated,
      anonymous: total - authenticated
    }
  end

  @doc """
  Increments click count for a link.
  """
  def increment_link_clicks(link_id) do
    from(l in ProfileLink, where: l.id == ^link_id)
    |> Repo.update_all(inc: [clicks: 1])
  end

  @doc """
  Follow a user.
  """
  def follow_user(follower_id, followed_id) do
    result =
      %Follow{}
      |> Follow.changeset(%{follower_id: follower_id, followed_id: followed_id})
      |> Repo.insert()

    case result do
      {:ok, follow} ->
        # Create notification for the followed user
        follower = Elektrine.Accounts.get_user!(follower_id)
        Elektrine.Notifications.notify_follow(followed_id, follower)
        {:ok, follow}

      error ->
        error
    end
  end

  @doc """
  Unfollow a user.
  """
  def unfollow_user(follower_id, followed_id) do
    Follow
    |> where([f], f.follower_id == ^follower_id and f.followed_id == ^followed_id)
    |> Repo.delete_all()
  end

  @doc """
  Check if a user is following another user.
  Only returns true for accepted follows (pending == false).
  """
  def following?(follower_id, followed_id) do
    Follow
    |> where(
      [f],
      f.follower_id == ^follower_id and f.followed_id == ^followed_id and f.pending == false
    )
    |> Repo.exists?()
  end

  @doc """
  Check which users from a list are being followed by the given user.
  Returns a map of user_id => boolean.
  Only counts accepted follows (pending == false).
  """
  def following_many?(follower_id, followed_ids) when is_list(followed_ids) do
    if Enum.empty?(followed_ids) do
      %{}
    else
      # Get all follows in a single query
      followed_set =
        Follow
        |> where(
          [f],
          f.follower_id == ^follower_id and f.followed_id in ^followed_ids and f.pending == false
        )
        |> select([f], f.followed_id)
        |> Repo.all()
        |> MapSet.new()

      # Build result map with true/false for each user_id
      followed_ids
      |> Enum.uniq()
      |> Enum.map(fn uid -> {uid, MapSet.member?(followed_set, uid)} end)
      |> Map.new()
    end
  end

  @doc """
  Get followers for a user (includes both local and remote followers).
  Only returns accepted follows (pending == false).
  """
  def get_followers(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    # Get local followers (only accepted)
    local_followers =
      Follow
      |> where(
        [f],
        f.followed_id == ^user_id and not is_nil(f.follower_id) and f.pending == false
      )
      |> join(:inner, [f], u in User, on: f.follower_id == u.id)
      |> select([f, u], %{
        type: "local",
        user: u,
        remote_actor: nil,
        followed_at: f.inserted_at
      })
      |> Repo.all()

    # Get remote followers - only accepted
    remote_followers =
      Follow
      |> where(
        [f],
        f.followed_id == ^user_id and not is_nil(f.remote_actor_id) and f.pending == false
      )
      |> join(:inner, [f], a in Elektrine.ActivityPub.Actor, on: f.remote_actor_id == a.id)
      |> select([f, a], %{
        type: "remote",
        user: nil,
        remote_actor: a,
        followed_at: f.inserted_at
      })
      |> Repo.all()

    # Combine and sort
    (local_followers ++ remote_followers)
    |> Enum.sort_by(& &1.followed_at, {:desc, NaiveDateTime})
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  @doc """
  Get users that a user is following (includes both local and remote users).
  Only returns accepted follows (pending == false).
  """
  def get_following(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    # Get local users being followed (only accepted)
    local_following =
      Follow
      |> where(
        [f],
        f.follower_id == ^user_id and not is_nil(f.followed_id) and f.pending == false
      )
      |> join(:inner, [f], u in User, on: f.followed_id == u.id)
      |> select([f, u], %{
        type: "local",
        user: u,
        remote_actor: nil,
        followed_at: f.inserted_at
      })
      |> Repo.all()

    # Get remote users being followed - only accepted
    remote_following =
      Follow
      |> where(
        [f],
        f.follower_id == ^user_id and not is_nil(f.remote_actor_id) and f.pending == false
      )
      |> join(:inner, [f], a in Elektrine.ActivityPub.Actor, on: f.remote_actor_id == a.id)
      |> select([f, a], %{
        type: "remote",
        user: nil,
        remote_actor: a,
        followed_at: f.inserted_at
      })
      |> Repo.all()

    # Combine and sort
    (local_following ++ remote_following)
    |> Enum.sort_by(& &1.followed_at, {:desc, NaiveDateTime})
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  @doc """
  Get follower count for a user (includes both local and remote).
  Only counts accepted follows (pending == false).
  """
  def get_follower_count(user_id) do
    Follow
    |> where([f], f.followed_id == ^user_id and f.pending == false)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Get following count for a user (includes both local and remote).
  Only counts accepted follows (pending == false).
  """
  def get_following_count(user_id) do
    Follow
    |> where([f], f.follower_id == ^user_id and f.pending == false)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Get mutual follows (users who follow each other).
  Only counts accepted follows (pending == false).
  """
  def get_mutual_follows(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    query = """
    SELECT u.*
    FROM users u
    INNER JOIN follows f1 ON f1.followed_id = u.id
    INNER JOIN follows f2 ON f2.follower_id = u.id
    WHERE f1.follower_id = $1 AND f2.followed_id = $1
      AND f1.pending = false AND f2.pending = false
    ORDER BY f1.inserted_at DESC
    LIMIT $2 OFFSET $3
    """

    {:ok, result} = Ecto.Adapters.SQL.query(Repo, query, [user_id, limit, offset])

    Enum.map(result.rows, fn row ->
      Repo.load(User, {result.columns, row})
    end)
  end

  # Badge Management

  def list_user_badges(user_id) do
    UserBadge
    |> where([b], b.user_id == ^user_id)
    |> order_by([b], b.position)
    |> Repo.all()
  end

  def list_visible_user_badges(user_id) do
    UserBadge
    |> where([b], b.user_id == ^user_id and b.visible == true)
    |> order_by([b], b.position)
    |> Repo.all()
  end

  def create_badge(attrs) do
    %UserBadge{}
    |> UserBadge.changeset(attrs)
    |> Repo.insert()
  end

  def update_badge(badge, attrs) do
    badge
    |> UserBadge.changeset(attrs)
    |> Repo.update()
  end

  def delete_badge(badge_id) do
    Repo.get!(UserBadge, badge_id)
    |> Repo.delete()
  end

  @doc """
  Grants a staff badge to a user.
  Can only be granted by admins.
  """
  def grant_staff_badge(user_id, granted_by_admin_id) do
    defaults = UserBadge.default_badge_properties("staff")

    attrs = %{
      user_id: user_id,
      badge_type: "staff",
      badge_text: defaults.badge_text,
      badge_color: defaults.badge_color,
      badge_icon: defaults.badge_icon,
      tooltip: defaults.tooltip,
      granted_by_id: granted_by_admin_id,
      visible: true,
      position: 0
    }

    create_badge(attrs)
  end

  @doc """
  Grants a predefined badge type to a user with default properties.
  """
  def grant_badge(user_id, badge_type, granted_by_admin_id)
      when badge_type in ~w(staff verified admin moderator supporter developer contributor beta_tester) do
    defaults = UserBadge.default_badge_properties(badge_type)

    attrs = %{
      user_id: user_id,
      badge_type: badge_type,
      badge_text: defaults.badge_text,
      badge_color: defaults.badge_color,
      badge_icon: defaults.badge_icon,
      tooltip: defaults.tooltip,
      granted_by_id: granted_by_admin_id,
      visible: true,
      position: 0
    }

    create_badge(attrs)
  end

  @doc """
  Checks if a user has a specific badge type.
  """
  def has_badge?(user_id, badge_type) do
    Repo.exists?(
      from b in UserBadge,
        where: b.user_id == ^user_id and b.badge_type == ^badge_type and b.visible == true
    )
  end

  @doc """
  Revokes all badges of a specific type from a user.
  """
  def revoke_badge(user_id, badge_type) do
    from(b in UserBadge,
      where: b.user_id == ^user_id and b.badge_type == ^badge_type
    )
    |> Repo.delete_all()
  end

  # Widget Management

  def list_profile_widgets(profile_id) do
    ProfileWidget
    |> where([w], w.profile_id == ^profile_id and w.is_active == true)
    |> order_by([w], w.position)
    |> Repo.all()
  end

  def create_widget(attrs) do
    %ProfileWidget{}
    |> ProfileWidget.changeset(attrs)
    |> Repo.insert()
  end

  def update_widget(widget, attrs) do
    widget
    |> ProfileWidget.changeset(attrs)
    |> Repo.update()
  end

  def delete_widget(widget_id) do
    Repo.get!(ProfileWidget, widget_id)
    |> Repo.delete()
  end

  def get_widget(id), do: Repo.get(ProfileWidget, id)

  # ActivityPub Federation Support

  @doc """
  Creates a follow from a remote actor.
  """
  def create_remote_follow(
        remote_actor_id,
        followed_user_id,
        pending \\ false,
        activitypub_id \\ nil
      ) do
    %Follow{}
    |> Follow.changeset(%{
      remote_actor_id: remote_actor_id,
      followed_id: followed_user_id,
      pending: pending,
      activitypub_id: activitypub_id
    })
    |> Repo.insert()
  end

  @doc """
  Deletes a follow from a remote actor.
  """
  def delete_remote_follow(remote_actor_id, followed_user_id) do
    Follow
    |> where([f], f.remote_actor_id == ^remote_actor_id and f.followed_id == ^followed_user_id)
    |> Repo.delete_all()
  end

  @doc """
  Gets a follow by remote actor and followed user.
  This is for when a REMOTE actor follows a LOCAL user.
  """
  def get_follow_by_remote_actor(remote_actor_id, followed_user_id) do
    Follow
    |> where([f], f.remote_actor_id == ^remote_actor_id and f.followed_id == ^followed_user_id)
    |> Repo.one()
  end

  @doc """
  Gets a follow where a LOCAL user follows a REMOTE actor.
  Returns the follow record regardless of pending status.
  """
  def get_follow_to_remote_actor(follower_id, remote_actor_id) do
    Follow
    |> where(
      [f],
      f.follower_id == ^follower_id and f.remote_actor_id == ^remote_actor_id and
        is_nil(f.followed_id)
    )
    |> Repo.one()
  end

  @doc """
  Checks if a LOCAL user is actively following a REMOTE actor (not pending).
  Returns true only if the follow exists and is accepted (pending == false).
  """
  def following_remote_actor?(follower_id, remote_actor_id) do
    Follow
    |> where(
      [f],
      f.follower_id == ^follower_id and f.remote_actor_id == ^remote_actor_id and
        is_nil(f.followed_id) and f.pending == false
    )
    |> Repo.exists?()
  end

  @doc """
  Follow a remote actor (local user following remote user).
  Sends ActivityPub Follow activity to the remote server.
  """
  def follow_remote_actor(follower_id, remote_actor_id) do
    require Logger

    with {:ok, follower} <- get_follower(follower_id),
         {:ok, follower} <- Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(follower),
         {:ok, remote_actor} <- get_remote_actor(remote_actor_id),
         {:ok, :not_following} <- check_not_already_following(follower_id, remote_actor_id) do
      # Build Follow activity
      follow_activity =
        Elektrine.ActivityPub.Builder.build_follow_activity(follower, remote_actor.uri)

      # Create pending follow relationship first
      case %Follow{}
           |> Ecto.Changeset.change(%{
             follower_id: follower_id,
             remote_actor_id: remote_actor_id,
             activitypub_id: follow_activity["id"],
             pending: true
           })
           |> Repo.insert() do
        {:ok, follow} ->
          # Send to remote inbox
          publish_result =
            Elektrine.ActivityPub.Publisher.publish(follow_activity, follower, [
              remote_actor.inbox_url
            ])

          case publish_result do
            {:ok, _activity_record} ->
              Logger.info(
                "Successfully sent Follow to #{remote_actor.username}@#{remote_actor.domain}"
              )

              {:ok, follow}

            unexpected ->
              Logger.error("Unexpected return from Publisher.publish: #{inspect(unexpected)}")
              # Clean up the follow record
              Repo.delete(follow)
              {:error, :unexpected_response}
          end

        {:error, changeset} ->
          Logger.error("Failed to create follow record: #{inspect(changeset)}")
          {:error, :database_error}
      end
    else
      {:error, :already_following} ->
        {:error, :already_following}

      {:error, :follower_not_found} ->
        Logger.error("Follower #{follower_id} not found")
        {:error, :follower_not_found}

      {:error, :remote_actor_not_found} ->
        Logger.error("Remote actor #{remote_actor_id} not found")
        {:error, :remote_actor_not_found}

      {:error, reason} = error ->
        Logger.error("Failed to follow remote actor: #{inspect(reason)}")
        error
    end
  end

  defp get_follower(follower_id) do
    case Repo.get(Elektrine.Accounts.User, follower_id) do
      nil -> {:error, :follower_not_found}
      user -> {:ok, user}
    end
  end

  defp get_remote_actor(remote_actor_id) do
    case Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id) do
      nil -> {:error, :remote_actor_not_found}
      actor -> {:ok, actor}
    end
  end

  defp check_not_already_following(follower_id, remote_actor_id) do
    case get_follow_to_remote_actor(follower_id, remote_actor_id) do
      nil -> {:ok, :not_following}
      %Follow{} -> {:error, :already_following}
    end
  end

  @doc """
  Unfollow a remote actor (local user unfollowing remote user).
  Sends ActivityPub Undo activity to the remote server.
  """
  def unfollow_remote_actor(follower_id, remote_actor_id) do
    with follow when not is_nil(follow) <-
           get_follow_to_remote_actor(follower_id, remote_actor_id),
         follower <- Elektrine.Accounts.get_user!(follower_id),
         remote_actor <- Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id) do
      # Build Undo activity
      original_follow = %{
        "id" => follow.activitypub_id,
        "type" => "Follow",
        "actor" => "#{Elektrine.ActivityPub.instance_url()}/users/#{follower.username}",
        "object" => remote_actor.uri
      }

      undo_activity = Elektrine.ActivityPub.Builder.build_undo_activity(follower, original_follow)

      # Delete the follow from database
      Follow
      |> where(
        [f],
        f.follower_id == ^follower_id and f.remote_actor_id == ^remote_actor_id and
          is_nil(f.followed_id)
      )
      |> Repo.delete_all()

      # Send Undo to remote inbox
      Elektrine.ActivityPub.Publisher.publish(undo_activity, follower, [remote_actor.inbox_url])

      {:ok, :unfollowed}
    else
      nil -> {:error, :not_following}
      error -> error
    end
  end

  @doc """
  Lists remote followers for a user (for sending activities).
  """
  def list_remote_followers(user_id) do
    Follow
    |> where([f], f.followed_id == ^user_id and not is_nil(f.remote_actor_id))
    |> Repo.all()
  end

  @doc """
  Gets pending follow requests for a user (from remote actors).
  """
  def get_pending_follow_requests(user_id) do
    Follow
    |> where(
      [f],
      f.followed_id == ^user_id and f.pending == true and not is_nil(f.remote_actor_id)
    )
    |> join(:inner, [f], a in Elektrine.ActivityPub.Actor, on: f.remote_actor_id == a.id)
    |> select([f, a], %{
      id: f.id,
      remote_actor: a,
      activitypub_id: f.activitypub_id,
      inserted_at: f.inserted_at
    })
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
  end

  @doc """
  Accepts a pending follow request.
  """
  def accept_follow_request(follow_id) do
    Follow
    |> where([f], f.id == ^follow_id)
    |> Repo.update_all(set: [pending: false])
  end

  @doc """
  Rejects and deletes a pending follow request.
  """
  def reject_follow_request(follow_id) do
    Follow
    |> where([f], f.id == ^follow_id)
    |> Repo.delete_all()
  end

  @doc """
  Accepts a follow request by activity ID.
  """
  def accept_follow_by_activity_id(activity_id) do
    # Get the follow before updating to broadcast to the user
    follow =
      Follow
      |> where([f], f.activitypub_id == ^activity_id)
      |> Repo.one()

    result =
      Follow
      |> where([f], f.activitypub_id == ^activity_id)
      |> Repo.update_all(set: [pending: false])

    # Broadcast follow acceptance to user's timeline if they're a local user
    if follow && follow.follower_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "user:#{follow.follower_id}:timeline",
        {:follow_accepted, follow.remote_actor_id}
      )
    end

    result
  end

  @doc """
  Deletes a follow by activity ID.
  """
  def delete_follow_by_activity_id(activity_id) do
    Follow
    |> where([f], f.activitypub_id == ^activity_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns following status for multiple local users in batch.
  Returns a list of {followed_id, :following | :pending | :not_following} tuples.
  """
  def following_status_batch(follower_id, followed_ids) when is_list(followed_ids) do
    if Enum.empty?(followed_ids) do
      []
    else
      follows =
        Follow
        |> where([f], f.follower_id == ^follower_id and f.followed_id in ^followed_ids)
        |> select([f], {f.followed_id, f.pending})
        |> Repo.all()
        |> Map.new()

      Enum.map(followed_ids, fn followed_id ->
        case Map.get(follows, followed_id) do
          nil -> {followed_id, :not_following}
          false -> {followed_id, :following}
          true -> {followed_id, :pending}
        end
      end)
    end
  end

  @doc """
  Returns following status for multiple remote actors in batch.
  Returns a list of {remote_actor_id, :following | :pending | :not_following} tuples.
  """
  def remote_following_status_batch(follower_id, remote_actor_ids)
      when is_list(remote_actor_ids) do
    if Enum.empty?(remote_actor_ids) do
      []
    else
      follows =
        Follow
        |> where(
          [f],
          f.follower_id == ^follower_id and f.remote_actor_id in ^remote_actor_ids and
            is_nil(f.followed_id)
        )
        |> select([f], {f.remote_actor_id, f.pending})
        |> Repo.all()
        |> Map.new()

      Enum.map(remote_actor_ids, fn actor_id ->
        case Map.get(follows, actor_id) do
          nil -> {actor_id, :not_following}
          false -> {actor_id, :following}
          true -> {actor_id, :pending}
        end
      end)
    end
  end
end
