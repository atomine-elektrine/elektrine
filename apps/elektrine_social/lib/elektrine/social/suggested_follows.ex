defmodule Elektrine.Social.SuggestedFollows do
  @moduledoc """
  Follow suggestions and suggestion dismissals.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.SuggestedAccountDismissal

  @doc """
  Get suggested users to follow based on various factors.
  """
  def get_suggested_follows(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    following_ids = list_following_ids(user_id)
    dismissed_ids = list_dismissed_suggested_follow_ids(user_id)

    suggestions =
      suggested_active_users(user_id, following_ids, limit) ++
        suggested_mutual_users(user_id, following_ids, limit) ++
        suggested_popular_users(user_id, following_ids, limit)

    suggestions
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id in dismissed_ids))
    |> Enum.take(limit)
    |> hydrate_suggested_follow_users()
  end

  @doc """
  Dismisses an account from a user's follow suggestions.
  """
  def dismiss_suggested_follow(user_id, suggested_user_id)
      when is_integer(user_id) and is_integer(suggested_user_id) and user_id != suggested_user_id do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SuggestedAccountDismissal{}
    |> SuggestedAccountDismissal.changeset(%{
      user_id: user_id,
      suggested_user_id: suggested_user_id,
      dismissed_at: now
    })
    |> Repo.insert(
      on_conflict: [set: [dismissed_at: now, updated_at: now]],
      conflict_target: [:user_id, :suggested_user_id]
    )
  end

  def dismiss_suggested_follow(_user_id, _suggested_user_id), do: {:error, :invalid_suggestion}

  defp list_dismissed_suggested_follow_ids(user_id) do
    from(dismissal in SuggestedAccountDismissal,
      where: dismissal.user_id == ^user_id,
      select: dismissal.suggested_user_id
    )
    |> Repo.all()
  end

  defp list_following_ids(user_id) do
    from(f in Follow, where: f.follower_id == ^user_id, select: f.followed_id)
    |> Repo.all()
  end

  defp suggested_active_users(user_id, following_ids, limit) do
    from(m in Message,
      join: u in User,
      on: u.id == m.sender_id,
      where:
        m.post_type == "post" and
          m.visibility in ["public", "followers"] and
          m.sender_id != ^user_id and
          m.sender_id not in ^following_ids and
          m.inserted_at > ago(7, "day") and
          not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      order_by: [desc: count(m.id), desc: max(m.inserted_at)],
      limit: ^(limit * 2),
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        post_count: count(m.id),
        reason: "Active poster"
      }
    )
    |> Repo.all()
  end

  defp suggested_mutual_users(user_id, following_ids, limit) do
    from(f1 in Follow,
      join: f2 in Follow,
      on: f1.followed_id == f2.follower_id,
      join: u in User,
      on: u.id == f2.followed_id,
      where:
        f1.follower_id == ^user_id and
          f2.followed_id != ^user_id and
          f2.followed_id not in ^following_ids and
          not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      order_by: [desc: count(f2.id)],
      limit: ^limit,
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        mutual_count: count(f2.id),
        reason: "Followed by people you follow"
      }
    )
    |> Repo.all()
  end

  defp suggested_popular_users(user_id, following_ids, limit) do
    from(u in User,
      left_join: f in Follow,
      on: f.followed_id == u.id,
      left_join: _p in assoc(u, :profile),
      where: u.id != ^user_id and u.id not in ^following_ids and not u.banned and not u.suspended,
      group_by: [u.id, u.username, u.handle, u.display_name, u.avatar],
      having: count(f.id) > 0,
      order_by: [desc: count(f.id)],
      limit: ^limit,
      select: %{
        id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        follower_count: count(f.id),
        reason: "Popular user"
      }
    )
    |> Repo.all()
  end

  defp hydrate_suggested_follow_users([]), do: []

  defp hydrate_suggested_follow_users(suggestions) do
    ids = Enum.map(suggestions, & &1.id)

    users_by_id =
      User
      |> where([user], user.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(suggestions, fn suggestion ->
      Map.put(suggestion, :user, Map.get(users_by_id, suggestion.id))
    end)
  end
end
