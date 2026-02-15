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

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Blocking
  alias Elektrine.Accounts.Muting
  alias Elektrine.Social
  alias Elektrine.Profiles
  alias Elektrine.Repo

  import Ecto.Query

  action_fallback(ElektrineWeb.MastodonAPI.FallbackController)

  @doc "GET /api/v1/accounts/verify_credentials"
  def verify_credentials(%{assigns: %{user: nil}} = _conn, _params) do
    {:error, :unauthorized}
  end

  def verify_credentials(%{assigns: %{user: user}} = conn, _params) do
    json(conn, render_account(user, user, with_source: true))
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
        followers = get_followers(user, params)
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
        following = get_following(user, params)
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
        case Social.follow_user(user, target) do
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
        case Social.unfollow_user(user, target) do
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
    cond do
      # Try as numeric ID
      is_integer(id_or_nickname) ->
        Repo.get(Elektrine.Accounts.User, id_or_nickname)

      String.match?(id_or_nickname, ~r/^\d+$/) ->
        Repo.get(Elektrine.Accounts.User, String.to_integer(id_or_nickname))

      # Try as username
      true ->
        Accounts.get_user_by_username(id_or_nickname)
    end
  end

  defp find_user_by_acct(acct) do
    # Handle both local usernames and full addresses (user@domain)
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
        preload: [:sender, :link_preview, reactions: :user]
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

  defp render_account(user, _for_user, opts \\ []) do
    base_url = ElektrineWeb.Endpoint.url()
    created_at = format_datetime(user.inserted_at)

    account = %{
      id: to_string(user.id),
      username: user.username,
      acct: user.username,
      display_name: user.display_name || user.username,
      locked: user.private || false,
      bot: false,
      discoverable: true,
      group: false,
      created_at: created_at,
      note: user.bio || "",
      url: "#{base_url}/#{user.username}",
      avatar: Elektrine.Uploads.avatar_url(user.avatar),
      avatar_static: Elektrine.Uploads.avatar_url(user.avatar),
      header: Elektrine.Uploads.background_url(user.background),
      header_static: Elektrine.Uploads.background_url(user.background),
      followers_count: get_followers_count(user),
      following_count: get_following_count(user),
      statuses_count: get_statuses_count(user),
      last_status_at: get_last_status_at(user),
      emojis: [],
      fields: render_fields(user)
    }

    # Add source for verify_credentials
    if Keyword.get(opts, :with_source, false) do
      Map.put(account, :source, %{
        privacy: "public",
        sensitive: false,
        language: user.locale || "en",
        note: user.bio || "",
        fields: render_fields(user)
      })
    else
      account
    end
  end

  defp render_relationship(user, target) do
    following = Accounts.is_following?(user.id, target.id)
    followed_by = Accounts.is_following?(target.id, user.id)
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

  defp render_fields(%{custom_fields: fields}) when is_list(fields) do
    Enum.map(fields, fn field ->
      %{
        name: field["name"] || field[:name] || "",
        value: field["value"] || field[:value] || "",
        verified_at: nil
      }
    end)
  end

  defp render_fields(_), do: []

  defp get_followers_count(%{id: user_id}) do
    Repo.one(
      from(f in "follows",
        where: f.following_id == ^user_id,
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
      from(p in "posts",
        where: p.user_id == ^user_id,
        select: count(p.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp get_last_status_at(%{id: user_id}) do
    case Repo.one(
           from(p in "posts",
             where: p.user_id == ^user_id,
             order_by: [desc: p.inserted_at],
             limit: 1,
             select: p.inserted_at
           )
         ) do
      nil -> nil
      datetime -> Date.to_iso8601(datetime)
    end
  rescue
    _ -> nil
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
