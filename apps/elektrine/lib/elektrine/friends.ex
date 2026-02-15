defmodule Elektrine.Friends do
  @moduledoc """
  The Friends context for managing friend requests and friendships.

  Xbox-style friend system:
  - Users send friend requests
  - Must be accepted to become friends
  - Friends have special privileges (calls, see online status, friends-only posts)
  - Independent from follow system (can follow without being friends)
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Friends.FriendRequest
  alias Elektrine.Accounts.User

  @doc """
  Sends a friend request from requester to recipient.
  """
  def send_friend_request(requester_id, recipient_id, message \\ nil) do
    # Check privacy settings first
    case Elektrine.Privacy.can_send_friend_request?(requester_id, recipient_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, :allowed} ->
        # Check if request already exists
        case get_friend_request(requester_id, recipient_id) do
          nil ->
            result =
              %FriendRequest{}
              |> FriendRequest.changeset(%{
                requester_id: requester_id,
                recipient_id: recipient_id,
                status: "pending",
                message: message
              })
              |> Repo.insert()

            # Invalidate pending requests cache for recipient
            case result do
              {:ok, _} ->
                Elektrine.AppCache.invalidate_friends_cache(recipient_id)

              _ ->
                :ok
            end

            result

          _existing ->
            {:error, :request_already_exists}
        end
    end
  end

  @doc """
  Accepts a friend request.
  Re-validates privacy settings at acceptance time to prevent stale requests.
  """
  def accept_friend_request(request_id, user_id) do
    request = Repo.get(FriendRequest, request_id)

    cond do
      !request ->
        {:error, :not_found}

      request.recipient_id != user_id ->
        {:error, :unauthorized}

      request.status != "pending" ->
        {:error, :already_processed}

      true ->
        # Re-validate privacy settings at acceptance time
        # This prevents accepting old requests after changing privacy to "nobody"
        case Elektrine.Privacy.can_send_friend_request?(request.requester_id, user_id) do
          {:error, :privacy_restricted} ->
            # Privacy settings changed - auto-reject the stale request
            request
            |> FriendRequest.changeset(%{status: "rejected"})
            |> Repo.update()
            |> case do
              {:ok, _} -> {:error, :privacy_settings_changed}
              error -> error
            end

          {:error, reason} ->
            {:error, reason}

          {:ok, :allowed} ->
            result =
              request
              |> FriendRequest.changeset(%{status: "accepted"})
              |> Repo.update()

            # Invalidate friends cache for both users
            case result do
              {:ok, _} ->
                Elektrine.AppCache.invalidate_friends_cache(request.requester_id)
                Elektrine.AppCache.invalidate_friends_cache(request.recipient_id)

              _ ->
                :ok
            end

            result
        end
    end
  end

  @doc """
  Rejects a friend request.
  """
  def reject_friend_request(request_id, user_id) do
    request = Repo.get(FriendRequest, request_id)

    cond do
      !request ->
        {:error, :not_found}

      request.recipient_id != user_id ->
        {:error, :unauthorized}

      request.status != "pending" ->
        {:error, :already_processed}

      true ->
        result =
          request
          |> FriendRequest.changeset(%{status: "rejected"})
          |> Repo.update()

        # Invalidate cache for recipient (pending requests count changes)
        case result do
          {:ok, _} ->
            Elektrine.AppCache.invalidate_friends_cache(user_id)

          _ ->
            :ok
        end

        result
    end
  end

  @doc """
  Cancels a sent friend request.
  """
  def cancel_friend_request(request_id, user_id) do
    request = Repo.get(FriendRequest, request_id)

    cond do
      !request ->
        {:error, :not_found}

      request.requester_id != user_id ->
        {:error, :unauthorized}

      request.status != "pending" ->
        {:error, :already_processed}

      true ->
        result = Repo.delete(request)

        # Invalidate cache for recipient (pending requests count changes)
        case result do
          {:ok, _} ->
            Elektrine.AppCache.invalidate_friends_cache(request.recipient_id)

          _ ->
            :ok
        end

        result
    end
  end

  @doc """
  Unfriends a user (deletes the accepted friend request).
  """
  def unfriend(user_id, friend_id) do
    # Find accepted friend request in either direction
    request =
      from(f in FriendRequest,
        where: f.status == "accepted",
        where:
          (f.requester_id == ^user_id and f.recipient_id == ^friend_id) or
            (f.requester_id == ^friend_id and f.recipient_id == ^user_id)
      )
      |> Repo.one()

    if request do
      result = Repo.delete(request)

      # Invalidate friends cache for both users
      case result do
        {:ok, _} ->
          Elektrine.AppCache.invalidate_friends_cache(user_id)
          Elektrine.AppCache.invalidate_friends_cache(friend_id)

        _ ->
          :ok
      end

      result
    else
      {:error, :not_friends}
    end
  end

  @doc """
  Checks if two users are friends.
  """
  def friends?(user_id, other_user_id) do
    Repo.exists?(
      from(f in FriendRequest,
        where: f.status == "accepted",
        where:
          (f.requester_id == ^user_id and f.recipient_id == ^other_user_id) or
            (f.requester_id == ^other_user_id and f.recipient_id == ^user_id)
      )
    )
  end

  @doc """
  Alias for friends?/2 for consistency.
  """
  def are_friends?(user_id, other_user_id), do: friends?(user_id, other_user_id)

  @doc """
  Gets a friend request between two users (in either direction).
  """
  def get_friend_request(user_id, other_user_id) do
    from(f in FriendRequest,
      where:
        (f.requester_id == ^user_id and f.recipient_id == ^other_user_id) or
          (f.requester_id == ^other_user_id and f.recipient_id == ^user_id)
    )
    |> Repo.one()
  end

  @doc """
  Lists all friends for a user (accepted requests in either direction).
  """
  def list_friends(user_id) do
    from(f in FriendRequest,
      where: f.status == "accepted",
      where: f.requester_id == ^user_id or f.recipient_id == ^user_id,
      preload: [:requester, :recipient]
    )
    |> Repo.all()
    |> Enum.map(fn request ->
      # Return the other user (not the current user)
      if request.requester_id == user_id do
        request.recipient
      else
        request.requester
      end
    end)
  end

  @doc """
  Checks if a user has any friend data (friends, pending, or sent requests).
  Fast check for loading skeleton optimization.
  """
  def user_has_any_friend_data?(user_id) do
    from(f in FriendRequest,
      where: f.requester_id == ^user_id or f.recipient_id == ^user_id,
      limit: 1,
      select: 1
    )
    |> Repo.exists?()
  end

  @doc """
  Lists pending friend requests received by a user.
  """
  def list_pending_requests(user_id) do
    from(f in FriendRequest,
      where: f.recipient_id == ^user_id,
      where: f.status == "pending",
      order_by: [desc: f.inserted_at],
      preload: [:requester]
    )
    |> Repo.all()
  end

  @doc """
  Lists pending friend requests sent by a user.
  """
  def list_sent_requests(user_id) do
    from(f in FriendRequest,
      where: f.requester_id == ^user_id,
      where: f.status == "pending",
      order_by: [desc: f.inserted_at],
      preload: [:recipient]
    )
    |> Repo.all()
  end

  @doc """
  Gets friend count for a user.
  """
  def get_friend_count(user_id) do
    from(f in FriendRequest,
      where: f.status == "accepted",
      where: f.requester_id == ^user_id or f.recipient_id == ^user_id,
      select: count(f.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets pending friend request count for a user.
  """
  def get_pending_request_count(user_id) do
    from(f in FriendRequest,
      where: f.recipient_id == ^user_id,
      where: f.status == "pending",
      select: count(f.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets the friendship and follow status between two users.
  Returns a map with:
  - :are_friends - boolean
  - :you_follow_them - boolean
  - :they_follow_you - boolean
  - :mutual_follow - boolean
  - :pending_request - friend request if exists
  """
  def get_relationship_status(user_id, other_user_id) do
    # Check friendship
    are_friends = friends?(user_id, other_user_id)

    # Check follow status
    you_follow_them = Elektrine.Profiles.following?(user_id, other_user_id)
    they_follow_you = Elektrine.Profiles.following?(other_user_id, user_id)

    # Check for pending request
    pending_request =
      from(f in FriendRequest,
        where: f.status == "pending",
        where:
          (f.requester_id == ^user_id and f.recipient_id == ^other_user_id) or
            (f.requester_id == ^other_user_id and f.recipient_id == ^user_id)
      )
      |> Repo.one()

    %{
      are_friends: are_friends,
      you_follow_them: you_follow_them,
      they_follow_you: they_follow_you,
      mutual_follow: you_follow_them && they_follow_you,
      pending_request: pending_request
    }
  end

  @doc """
  Gets suggested friends (people you follow who follow you back, but aren't friends yet).
  Essentially mutual follows who haven't sent/accepted friend requests.
  """
  def get_suggested_friends(user_id, limit \\ 10) do
    # Get mutual follows
    mutual_follow_ids =
      from(f1 in Elektrine.Profiles.Follow,
        join: f2 in Elektrine.Profiles.Follow,
        on: f1.followed_id == f2.follower_id and f1.follower_id == f2.followed_id,
        where: f1.follower_id == ^user_id,
        select: f1.followed_id
      )
      |> Repo.all()

    # Get users who are already friends or have pending requests
    existing_friend_ids =
      from(f in FriendRequest,
        where: f.requester_id == ^user_id or f.recipient_id == ^user_id,
        where: f.status in ["accepted", "pending"],
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            f.requester_id,
            ^user_id,
            f.recipient_id,
            f.requester_id
          )
      )
      |> Repo.all()

    # Suggest mutual follows who aren't friends yet
    suggested_ids = mutual_follow_ids -- existing_friend_ids

    from(u in User,
      where: u.id in ^suggested_ids,
      limit: ^limit,
      preload: [:profile]
    )
    |> Repo.all()
  end
end
