defmodule ElektrineWeb.API.AccountJSON do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.{Actor, Helpers}
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  def format_accounts(accounts, viewer \\ nil) when is_list(accounts) do
    counts = account_count_context(accounts)

    Enum.map(accounts, &format_account(&1, viewer, counts))
  end

  def format_account(account, viewer \\ nil)

  def format_account(%User{} = user, viewer) do
    format_account(user, viewer, account_count_context([user]))
  end

  def format_account(%Actor{} = actor, viewer) do
    format_account(actor, viewer, %{})
  end

  def format_account(nil, _viewer), do: nil

  def format_account(%User{} = user, viewer, counts) do
    acct = user.handle || user.username

    %{
      id: to_string(user.id),
      username: user.username,
      acct: acct,
      display_name: user.display_name || user.username,
      note: "",
      url: Elektrine.Domains.profile_url_for_user(user) || "/#{acct}",
      avatar: user.avatar,
      avatar_static: user.avatar,
      header: nil,
      header_static: nil,
      fields: [],
      emojis: [],
      locked: user.activitypub_manually_approve_followers || false,
      bot: false,
      discoverable: user.profile_visibility != "private",
      followers_count: visible_followers_count(user, viewer, counts),
      following_count: visible_following_count(user, viewer, counts),
      statuses_count: count_value(counts, user.id, :statuses),
      last_status_at: last_status_at(counts, user.id),
      created_at: user.inserted_at,
      remote: false,
      pleroma: %{
        birthday: visible_birthday(user, viewer),
        also_known_as: user.also_known_as || [],
        moved_to: user.moved_to,
        hide_followers: user.hide_followers || false,
        hide_follows: user.hide_follows || false,
        hide_favorites: user.hide_favorites || false
      }
    }
  end

  def format_account(%Actor{} = actor, _viewer, _counts) do
    metadata = actor.metadata || %{}
    acct = Enum.reject([actor.username, actor.domain], &is_nil/1) |> Enum.join("@")

    %{
      id: "remote:#{actor.id}",
      username: actor.username,
      acct: acct,
      display_name: actor.display_name || actor.username,
      note: actor.summary || "",
      url: actor.uri,
      avatar: actor.avatar_url,
      avatar_static: actor.avatar_url,
      header: actor.header_url,
      header_static: actor.header_url,
      fields: actor_fields(metadata),
      emojis: actor_emojis(metadata),
      locked: actor.manually_approves_followers || false,
      bot: actor.actor_type in ["Service", "Application"],
      discoverable: true,
      followers_count: Helpers.get_follower_count(metadata),
      following_count: Helpers.get_following_count(metadata),
      statuses_count: Helpers.get_status_count(metadata),
      last_status_at: actor_last_status_at(metadata),
      created_at: actor.published_at || actor.inserted_at,
      remote: true
    }
  end

  def format_account(nil, _viewer, _counts), do: nil

  def format_status_account(status, viewer \\ nil)

  def format_status_account(%Message{sender: %User{} = user}, viewer),
    do: format_account(user, viewer)

  def format_status_account(%Message{remote_actor: %Actor{} = actor}, viewer),
    do: format_account(actor, viewer)

  def format_status_account(_status, _viewer), do: nil

  def format_status_account(status, viewer, counts)

  def format_status_account(%Message{sender: %User{} = user}, viewer, counts),
    do: format_account(user, viewer, counts)

  def format_status_account(%Message{remote_actor: %Actor{} = actor}, viewer, counts),
    do: format_account(actor, viewer, counts)

  def format_status_account(_status, _viewer, _counts), do: nil

  def account_count_context(accounts) when is_list(accounts) do
    accounts
    |> Enum.flat_map(fn
      %User{} = user -> [user.id]
      _account -> []
    end)
    |> user_count_context()
  end

  def status_account_count_context(statuses) when is_list(statuses) do
    statuses
    |> Enum.flat_map(fn
      %Message{sender: %User{id: user_id}} -> [user_id]
      _status -> []
    end)
    |> user_count_context()
  end

  def visible_followers_count(%User{} = account, viewer, counts) do
    if owner?(account, viewer) or account.hide_followers != true do
      count_value(counts, account.id, :followers)
    else
      0
    end
  end

  def visible_following_count(%User{} = account, viewer, counts) do
    if owner?(account, viewer) or account.hide_follows != true do
      count_value(counts, account.id, :following)
    else
      0
    end
  end

  def statuses_count(%User{} = account),
    do: count_value(user_count_context([account.id]), account.id, :statuses)

  def last_status_at(%User{} = account),
    do: last_status_at(user_count_context([account.id]), account.id)

  def visible_followers_count(%User{} = account, viewer),
    do: visible_followers_count(account, viewer, user_count_context([account.id]))

  def visible_following_count(%User{} = account, viewer),
    do: visible_following_count(account, viewer, user_count_context([account.id]))

  defp user_count_context(user_ids) do
    user_ids =
      user_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      followers: follower_counts(user_ids),
      following: following_counts(user_ids),
      statuses: status_counts(user_ids),
      last_status_at: last_status_dates(user_ids)
    }
  end

  defp follower_counts([]), do: %{}

  defp follower_counts(user_ids) do
    Follow
    |> where([follow], follow.followed_id in ^user_ids)
    |> where([follow], follow.pending == false)
    |> group_by([follow], follow.followed_id)
    |> select([follow], {follow.followed_id, count(follow.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp following_counts([]), do: %{}

  defp following_counts(user_ids) do
    local_counts =
      Follow
      |> where([follow], follow.follower_id in ^user_ids)
      |> where([follow], not is_nil(follow.followed_id))
      |> where([follow], follow.pending == false)
      |> group_by([follow], follow.follower_id)
      |> select([follow], {follow.follower_id, count(follow.id)})
      |> Repo.all()
      |> Map.new()

    remote_counts =
      Follow
      |> join(:inner, [follow], actor in Actor, on: follow.remote_actor_id == actor.id)
      |> where([follow, _actor], follow.follower_id in ^user_ids)
      |> where([follow, _actor], not is_nil(follow.remote_actor_id))
      |> where(
        [follow, actor],
        follow.pending == false or actor.manually_approves_followers == false
      )
      |> group_by([follow, _actor], follow.follower_id)
      |> select([follow, _actor], {follow.follower_id, count(follow.id)})
      |> Repo.all()
      |> Map.new()

    Map.merge(local_counts, remote_counts, fn _user_id, local, remote -> local + remote end)
  end

  defp status_counts([]), do: %{}

  defp status_counts(user_ids) do
    Message
    |> where([message], message.sender_id in ^user_ids)
    |> where([message], message.post_type == "post")
    |> where([message], message.is_draft != true)
    |> where([message], is_nil(message.deleted_at))
    |> where([message], message.approval_status == "approved" or is_nil(message.approval_status))
    |> group_by([message], message.sender_id)
    |> select([message], {message.sender_id, count(message.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp last_status_dates([]), do: %{}

  defp last_status_dates(user_ids) do
    Message
    |> where([message], message.sender_id in ^user_ids)
    |> where([message], message.post_type == "post")
    |> where([message], message.is_draft != true)
    |> where([message], is_nil(message.deleted_at))
    |> where([message], message.approval_status == "approved" or is_nil(message.approval_status))
    |> group_by([message], message.sender_id)
    |> select([message], {message.sender_id, max(fragment("date(?)", message.inserted_at))})
    |> Repo.all()
    |> Map.new()
  end

  defp count_value(counts, user_id, key) when is_map(counts) do
    counts
    |> Map.get(key, %{})
    |> Map.get(user_id, 0)
  end

  defp last_status_at(counts, user_id) when is_map(counts) do
    counts
    |> Map.get(:last_status_at, %{})
    |> Map.get(user_id)
  end

  def visible_birthday(%User{} = user, viewer) do
    if owner?(user, viewer) or user.show_birthday == true do
      user.birthday
    else
      nil
    end
  end

  defp owner?(%User{id: id}, %User{id: id}), do: true
  defp owner?(%User{id: id}, id) when is_integer(id), do: true
  defp owner?(_account, _viewer), do: false

  defp actor_fields(metadata) when is_map(metadata) do
    case metadata["fields"] || metadata[:fields] do
      fields when is_list(fields) -> fields
      _ -> []
    end
  end

  defp actor_fields(_metadata), do: []

  defp actor_emojis(metadata) when is_map(metadata) do
    case metadata["emojis"] || metadata[:emojis] || metadata["emoji"] || metadata[:emoji] do
      emojis when is_list(emojis) -> emojis
      _ -> []
    end
  end

  defp actor_emojis(_metadata), do: []

  defp actor_last_status_at(metadata) when is_map(metadata) do
    metadata["last_status_at"] || metadata[:last_status_at]
  end

  defp actor_last_status_at(_metadata), do: nil
end
