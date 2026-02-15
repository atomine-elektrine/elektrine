defmodule Elektrine.Social.HashtagFollows do
  @moduledoc """
  Context for managing hashtag follows.

  Users can follow hashtags to have posts containing them appear in their timeline.
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Social.{Hashtag, HashtagFollow}

  @doc """
  Follows a hashtag for a user.
  Creates the hashtag if it doesn't exist.
  """
  def follow_hashtag(user_id, hashtag_name) when is_binary(hashtag_name) do
    hashtag_name = normalize_hashtag(hashtag_name)

    # Get or create the hashtag
    hashtag = Elektrine.Social.get_or_create_hashtag(hashtag_name)

    if hashtag do
      %HashtagFollow{}
      |> HashtagFollow.changeset(%{user_id: user_id, hashtag_id: hashtag.id})
      |> Repo.insert(on_conflict: :nothing)
    else
      {:error, :invalid_hashtag}
    end
  end

  @doc """
  Unfollows a hashtag for a user.
  """
  def unfollow_hashtag(user_id, hashtag_name) when is_binary(hashtag_name) do
    hashtag_name = normalize_hashtag(hashtag_name)

    from(hf in HashtagFollow,
      join: h in Hashtag,
      on: h.id == hf.hashtag_id,
      where: hf.user_id == ^user_id,
      where: h.name == ^hashtag_name
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Checks if a user is following a hashtag.
  """
  def following?(user_id, hashtag_name) when is_binary(hashtag_name) do
    hashtag_name = normalize_hashtag(hashtag_name)

    from(hf in HashtagFollow,
      join: h in Hashtag,
      on: h.id == hf.hashtag_id,
      where: hf.user_id == ^user_id,
      where: h.name == ^hashtag_name
    )
    |> Repo.exists?()
  end

  @doc """
  Gets all hashtags a user is following.
  """
  def list_followed_hashtags(user_id) do
    from(h in Hashtag,
      join: hf in HashtagFollow,
      on: hf.hashtag_id == h.id,
      where: hf.user_id == ^user_id,
      order_by: [asc: h.name],
      select: h
    )
    |> Repo.all()
  end

  @doc """
  Gets all hashtag IDs a user is following.
  Useful for filtering timeline queries.
  """
  def followed_hashtag_ids(user_id) do
    from(hf in HashtagFollow,
      where: hf.user_id == ^user_id,
      select: hf.hashtag_id
    )
    |> Repo.all()
  end

  @doc """
  Gets all user IDs following a specific hashtag.
  Useful for broadcasting to hashtag followers.
  """
  def get_hashtag_followers(hashtag_name) when is_binary(hashtag_name) do
    hashtag_name = normalize_hashtag(hashtag_name)

    from(hf in HashtagFollow,
      join: h in Hashtag,
      on: h.id == hf.hashtag_id,
      where: h.name == ^hashtag_name,
      select: hf.user_id
    )
    |> Repo.all()
  end

  @doc """
  Counts followers for a hashtag.
  """
  def count_followers(hashtag_name) when is_binary(hashtag_name) do
    hashtag_name = normalize_hashtag(hashtag_name)

    from(hf in HashtagFollow,
      join: h in Hashtag,
      on: h.id == hf.hashtag_id,
      where: h.name == ^hashtag_name,
      select: count(hf.id)
    )
    |> Repo.one() || 0
  end

  @doc """
  Gets popular hashtags based on follower count.
  """
  def popular_hashtags(limit \\ 20) do
    from(h in Hashtag,
      join: hf in HashtagFollow,
      on: hf.hashtag_id == h.id,
      group_by: h.id,
      order_by: [desc: count(hf.id)],
      limit: ^limit,
      select: %{hashtag: h, follower_count: count(hf.id)}
    )
    |> Repo.all()
  end

  defp normalize_hashtag(name) do
    name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end
end
