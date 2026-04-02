defmodule ElektrineWeb.MastodonAPI.AccountController do
  @moduledoc """
  Controller for Mastodon API account operations.

  Provides endpoints for user account management, viewing profiles,
  and managing relationships (follow, block, mute).

  ## Endpoints

  * `GET /api/v1/accounts/verify_credentials` - Get current user
  * `GET /api/v1/accounts/:id` - Get account by ID
  * `GET /api/v1/accounts/:id/statuses` - Get account's statuses
  * `GET /api/v1/accounts/:id/followers` - Get account's followers
  * `GET /api/v1/accounts/:id/following` - Get accounts the user follows
  * `GET /api/v1/accounts/relationships` - Get relationships with accounts
  * `POST /api/v1/accounts/:id/follow` - Follow an account
  * `POST /api/v1/accounts/:id/unfollow` - Unfollow an account
  * `POST /api/v1/accounts/:id/block` - Block an account
  * `POST /api/v1/accounts/:id/unblock` - Unblock an account
  * `POST /api/v1/accounts/:id/mute` - Mute an account
  * `POST /api/v1/accounts/:id/unmute` - Unmute an account
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Blocking
  alias Elektrine.Accounts.Muting
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.Message
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social

  import Ecto.Query

  action_fallback(ElektrineWeb.MastodonAPI.FallbackController)

  @doc "GET /api/v1/accounts/verify_credentials"
  def verify_credentials(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def verify_credentials(%{assigns: %{user: user}} = conn, _params) do
    json(conn, render_account(preload_account_subject(user), user, with_source: true))
  end

  @doc "GET /api/v1/accounts/lookup"
  def lookup(conn, %{"acct" => acct}) do
    for_user = conn.assigns[:user]

    case find_user_by_acct(acct) do
      nil -> {:error, :not_found}
      user -> json(conn, render_account(user, for_user))
    end
  end

  def lookup(_conn, _params), do: {:error, :not_found}

  @doc "GET /api/v1/accounts/:id"
  def show(conn, %{"id" => id}) do
    for_user = conn.assigns[:user]

    case get_user_by_id_or_nickname(id) do
      nil -> {:error, :not_found}
      user -> json(conn, render_account(user, for_user))
    end
  end

  @doc "GET /api/v1/accounts/:id/statuses"
  def statuses(conn, %{"id" => id} = params) do
    for_user = conn.assigns[:user]

    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      user ->
        statuses = get_user_statuses(user, for_user, params)
        json(conn, Enum.map(statuses, &render_status(&1, for_user)))
    end
  end

  @doc "GET /api/v1/accounts/:id/followers"
  def followers(conn, %{"id" => id} = params) do
    for_user = conn.assigns[:user]

    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      user ->
        followers = get_followers(user, params) |> preload_account_subjects()
        json(conn, Enum.map(followers, &render_account(&1, for_user)))
    end
  end

  @doc "GET /api/v1/accounts/:id/following"
  def following(conn, %{"id" => id} = params) do
    for_user = conn.assigns[:user]

    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      user ->
        following = get_following(user, params) |> preload_account_subjects()
        json(conn, Enum.map(following, &render_account(&1, for_user)))
    end
  end

  @doc "GET /api/v1/accounts/relationships"
  def relationships(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def relationships(%{assigns: %{user: user}} = conn, params) do
    ids = get_id_list(params)

    relationships =
      ids
      |> Enum.map(&get_user_by_id_or_nickname/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&render_relationship(user, &1))

    json(conn, relationships)
  end

  @doc "POST /api/v1/accounts/:id/follow"
  def follow(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def follow(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target when target.id == user.id ->
        {:error, :unprocessable_entity, "Cannot follow yourself"}

      target ->
        case Social.follow_user(user.id, target.id) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, reason} -> {:error, :unprocessable_entity, to_string(reason)}
        end
    end
  end

  @doc "POST /api/v1/accounts/:id/unfollow"
  def unfollow(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def unfollow(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target ->
        case Social.unfollow_user(user.id, target.id) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, reason} -> {:error, :unprocessable_entity, to_string(reason)}
        end
    end
  end

  @doc "POST /api/v1/accounts/:id/block"
  def block(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def block(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target when target.id == user.id ->
        {:error, :unprocessable_entity, "Cannot block yourself"}

      target ->
        case Blocking.block_user(user.id, target.id) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, reason} -> {:error, :unprocessable_entity, to_string(reason)}
        end
    end
  end

  @doc "POST /api/v1/accounts/:id/unblock"
  def unblock(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def unblock(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target ->
        case Blocking.unblock_user(user.id, target.id) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, _reason} -> json(conn, render_relationship(user, target))
        end
    end
  end

  @doc "POST /api/v1/accounts/:id/mute"
  def mute(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def mute(%{assigns: %{user: user}} = conn, %{"id" => id} = params) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target when target.id == user.id ->
        {:error, :unprocessable_entity, "Cannot mute yourself"}

      target ->
        mute_notifications = parse_bool(Map.get(params, "notifications"), false)

        case Muting.mute_user(user.id, target.id, mute_notifications) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, reason} -> {:error, :unprocessable_entity, to_string(reason)}
        end
    end
  end

  @doc "POST /api/v1/accounts/:id/unmute"
  def unmute(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def unmute(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    case get_user_by_id_or_nickname(id) do
      nil ->
        {:error, :not_found}

      target ->
        case Muting.unmute_user(user.id, target.id) do
          {:ok, _} -> json(conn, render_relationship(user, target))
          {:error, :not_muted} -> json(conn, render_relationship(user, target))
          {:error, reason} -> {:error, :unprocessable_entity, to_string(reason)}
        end
    end
  end

  # Private functions

  defp get_user_by_id_or_nickname(id_or_nickname) do
    user =
      cond do
        # Try as numeric ID
        is_integer(id_or_nickname) ->
          Repo.get(User, id_or_nickname)

        String.match?(id_or_nickname, ~r/^\d+$/) ->
          Repo.get(User, String.to_integer(id_or_nickname))

        # Try as username
        true ->
          Accounts.get_user_by_username(id_or_nickname)
      end

    preload_account_subject(user)
  end

  defp find_user_by_acct(acct) do
    # Handle both local usernames and full addresses (user@domain)
    user =
      case String.split(acct, "@") do
        [username] ->
          Accounts.get_user_by_username(username)

        [username, domain] ->
          host = ElektrineWeb.Endpoint.host()

          if domain == host do
            Accounts.get_user_by_username(username)
          else
            # Remote account lookup is not supported in this endpoint.
            nil
          end

        _ ->
          nil
      end

    preload_account_subject(user)
  end

  defp get_id_list(%{"id" => ids}) when is_list(ids), do: ids
  defp get_id_list(%{"id" => id}), do: [id]
  defp get_id_list(%{"id[]" => ids}) when is_list(ids), do: ids
  defp get_id_list(%{"id[]" => id}), do: [id]
  defp get_id_list(_), do: []

  defp get_user_statuses(user, _for_user, params) do
    limit = min(Map.get(params, "limit", "20") |> parse_int(20), 40)

    # Get posts from the user - using messages table with public visibility
    query =
      from(m in Elektrine.Messaging.Message,
        where: m.sender_id == ^user.id,
        where: m.visibility in ["public", "unlisted"],
        where: is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [:link_preview, reactions: :user, sender: [profile: :links]]
      )

    # Filter based on params
    query =
      if params["exclude_replies"] == "true" do
        from(m in query, where: is_nil(m.reply_to_id))
      else
        query
      end

    query =
      if params["only_media"] == "true" do
        from(m in query, where: m.media_urls != [] and m.media_urls != fragment("'{}'"))
      else
        query
      end

    # Note: pinned posts not yet implemented in messages

    Repo.all(query)
  rescue
    _ -> []
  end

  defp get_followers(user, params) do
    limit = min(Map.get(params, "limit", "40") |> parse_int(40), 80)

    Profiles.get_followers(user.id, limit: limit)
  rescue
    _ -> []
  end

  defp get_following(user, params) do
    limit = min(Map.get(params, "limit", "40") |> parse_int(40), 80)

    Profiles.get_following(user.id, limit: limit)
  rescue
    _ -> []
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_bool(value, _default) when is_boolean(value), do: value

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp parse_bool(_, default), do: default

  # Rendering functions

  defp render_account(subject, for_user, opts \\ [])

  defp render_account(%{type: "local", user: %User{} = user}, for_user, opts) do
    render_account(user, for_user, opts)
  end

  defp render_account(%{type: "remote", remote_actor: %Actor{} = actor}, _for_user, _opts) do
    acct = remote_actor_acct(actor)

    %{
      id: to_string(actor.id),
      username: actor.username,
      acct: acct,
      display_name: actor.display_name || actor.username,
      locked: actor.manually_approves_followers || false,
      bot: actor.actor_type in ["Application", "Service"],
      discoverable: true,
      group: actor.actor_type == "Group",
      created_at: format_datetime(actor.published_at || actor.inserted_at),
      note: actor.summary || "",
      url: actor.uri || "",
      avatar: actor.avatar_url || "",
      avatar_static: actor.avatar_url || "",
      header: actor.header_url || "",
      header_static: actor.header_url || "",
      followers_count: 0,
      following_count: 0,
      statuses_count: 0,
      last_status_at: nil,
      emojis: [],
      fields: []
    }
  end

  defp render_account(user, _for_user, opts) do
    base_url = ElektrineWeb.Endpoint.url()
    created_at = format_datetime(user.inserted_at)
    note = account_note(user)
    header = account_header(user)
    fields = render_fields(user)

    account = %{
      id: to_string(user.id),
      username: user.username,
      acct: user.username,
      display_name: user.display_name || user.username,
      locked:
        Map.get(user, :private, Map.get(user, :activitypub_manually_approve_followers, false)),
      bot: false,
      discoverable: Map.get(user, :profile_visibility, "public") == "public",
      group: false,
      created_at: created_at,
      note: note,
      url: "#{base_url}/#{user.username}",
      avatar: Elektrine.Uploads.avatar_url(user.avatar),
      avatar_static: Elektrine.Uploads.avatar_url(user.avatar),
      header: Elektrine.Uploads.background_url(header),
      header_static: Elektrine.Uploads.background_url(header),
      followers_count: get_followers_count(user),
      following_count: get_following_count(user),
      statuses_count: get_statuses_count(user),
      last_status_at: get_last_status_at(user),
      emojis: [],
      fields: fields
    }

    # Add source for verify_credentials
    if Keyword.get(opts, :with_source, false) do
      Map.put(account, :source, %{
        privacy: "public",
        sensitive: false,
        language: user.locale || "en",
        note: note,
        fields: fields
      })
    else
      account
    end
  end

  defp render_relationship(user, target) do
    following = Accounts.following?(user.id, target.id)
    followed_by = Accounts.following?(target.id, user.id)
    blocking = Blocking.user_blocked?(user.id, target.id)
    blocked_by = Blocking.user_blocked?(target.id, user.id)
    muting = Muting.user_muted?(user.id, target.id)
    muting_notifications = muting and Muting.user_muting_notifications?(user.id, target.id)

    %{
      id: to_string(target.id),
      following: following,
      showing_reblogs: following,
      notifying: false,
      followed_by: followed_by,
      blocking: blocking,
      blocked_by: blocked_by,
      muting: muting,
      muting_notifications: muting_notifications,
      requested: false,
      domain_blocking: false,
      endorsed: false,
      note: ""
    }
  end

  defp render_status(post, for_user) do
    # Basic status rendering - this will be expanded in StatusController
    ElektrineWeb.MastodonAPI.StatusView.render_status(post, for_user)
  end

  defp render_fields(%{profile: %{links: links}}) when is_list(links) do
    links
    |> Enum.filter(&(&1.is_active != false))
    |> Enum.map(fn link ->
      %{
        name: link.title || "",
        value: link.url || "",
        verified_at: nil
      }
    end)
  end

  defp render_fields(%{profile: %{links: %Ecto.Association.NotLoaded{}}} = user) do
    render_legacy_fields(Map.get(user, :custom_fields))
  end

  defp render_fields(%{profile: nil} = user) do
    render_legacy_fields(Map.get(user, :custom_fields))
  end

  defp render_fields(%{custom_fields: fields}) when is_list(fields) do
    render_legacy_fields(fields)
  end

  defp render_fields(_), do: []

  defp render_legacy_fields(fields) when is_list(fields) do
    Enum.map(fields, fn field ->
      %{
        name: field["name"] || field[:name] || "",
        value: field["value"] || field[:value] || "",
        verified_at: nil
      }
    end)
  end

  defp render_legacy_fields(_), do: []

  defp preload_account_subject(nil), do: nil

  defp preload_account_subject(%User{} = user) do
    Repo.preload(user, profile: :links)
  end

  defp preload_account_subject(subject), do: subject

  defp preload_account_subjects(subjects) when is_list(subjects) do
    user_ids =
      subjects
      |> Enum.flat_map(fn
        %{type: "local", user: %User{id: id}} -> [id]
        %User{id: id} -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    if user_ids == [] do
      subjects
    else
      users_by_id =
        User
        |> where([u], u.id in ^user_ids)
        |> preload(profile: :links)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})

      Enum.map(subjects, fn
        %{type: "local", user: %User{id: id}} = subject ->
          %{subject | user: Map.get(users_by_id, id, subject.user)}

        %User{id: id} = user ->
          Map.get(users_by_id, id, user)

        subject ->
          subject
      end)
    end
  end

  defp account_note(%{profile: %Ecto.Association.NotLoaded{}} = user),
    do: Map.get(user, :bio) || ""

  defp account_note(%{profile: nil} = user), do: Map.get(user, :bio) || ""

  defp account_note(%{profile: profile} = user) when is_map(profile) do
    Map.get(profile, :description) || Map.get(user, :bio) || ""
  end

  defp account_note(user), do: Map.get(user, :bio) || ""

  defp account_header(%{profile: %Ecto.Association.NotLoaded{}} = user),
    do: Map.get(user, :background)

  defp account_header(%{profile: nil} = user), do: Map.get(user, :background)

  defp account_header(%{profile: profile} = user) when is_map(profile) do
    Map.get(profile, :banner_url) || Map.get(profile, :background_url) ||
      Map.get(user, :background)
  end

  defp account_header(user), do: Map.get(user, :background)

  defp remote_actor_acct(%Actor{username: username, domain: domain})
       when is_binary(domain) and domain != "" do
    "#{username}@#{domain}"
  end

  defp remote_actor_acct(%Actor{username: username}), do: username

  defp get_followers_count(%{id: user_id}) do
    Repo.one(
      from(f in "follows",
        where: f.followed_id == ^user_id,
        select: count(f.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp get_following_count(%{id: user_id}) do
    Repo.one(
      from(f in "follows",
        where: f.follower_id == ^user_id,
        select: count(f.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp get_statuses_count(%{id: user_id}) do
    Repo.one(
      from(m in Message,
        where: m.sender_id == ^user_id,
        where: m.visibility in ["public", "unlisted"],
        where: is_nil(m.deleted_at),
        select: count(m.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp get_last_status_at(%{id: user_id}) do
    Repo.one(
      from(m in Message,
        where: m.sender_id == ^user_id,
        where: m.visibility in ["public", "unlisted"],
        where: is_nil(m.deleted_at),
        select: max(m.inserted_at)
      )
    )
    |> to_iso_date()
  rescue
    _ -> nil
  end

  defp to_iso_date(nil), do: nil
  defp to_iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp to_iso_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp to_iso_date(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> Date.to_iso8601()
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
