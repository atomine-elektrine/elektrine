defmodule Elektrine.Social.NotificationPolicy do
  @moduledoc """
  Policy gate for social notifications.
  """

  import Ecto.Query

  alias Elektrine.Accounts.{User, UserBlock, UserMute}
  alias Elektrine.ActivityPub.{Actor, Instance}
  alias Elektrine.ActivityPub.UserBlock, as: ActivityPubUserBlock
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.{FeedPolicy, Message, ThreadMutes}

  def should_deliver?(attrs) when is_map(attrs) do
    user_id = attr(attrs, :user_id)

    cond do
      not is_integer(user_id) ->
        true

      local_actor_blocked?(user_id, attr(attrs, :actor_id)) ->
        false

      remote_actor_blocked?(user_id, remote_actor_id(attrs)) ->
        false

      stranger_notifications_blocked?(user_id, attrs) ->
        false

      source_message_blocked?(user_id, attrs) ->
        false

      source_thread_muted?(user_id, attrs) ->
        false

      true ->
        true
    end
  end

  def should_deliver?(_attrs), do: true

  defp stranger_notifications_blocked?(user_id, attrs) do
    case load_user(user_id) do
      %User{block_notifications_from_strangers: true} ->
        cond do
          followed_local_actor?(user_id, attr(attrs, :actor_id)) ->
            false

          followed_remote_actor?(user_id, remote_actor_id(attrs)) ->
            false

          actor_present?(attrs) ->
            true

          true ->
            false
        end

      _ ->
        false
    end
  end

  defp load_user(user_id) when is_integer(user_id) do
    Repo.get(User, user_id)
  end

  defp followed_local_actor?(user_id, actor_id) when is_integer(actor_id) do
    user_id == actor_id or
      Repo.exists?(
        from f in Follow,
          where:
            f.follower_id == ^user_id and f.followed_id == ^actor_id and
              (is_nil(f.pending) or f.pending == false)
      )
  end

  defp followed_local_actor?(_user_id, _actor_id), do: false

  defp followed_remote_actor?(user_id, remote_actor_id) when is_integer(remote_actor_id) do
    Repo.exists?(
      from f in Follow,
        where:
          f.follower_id == ^user_id and f.remote_actor_id == ^remote_actor_id and
            (is_nil(f.pending) or f.pending == false)
    )
  end

  defp followed_remote_actor?(_user_id, _remote_actor_id), do: false

  defp actor_present?(attrs) do
    is_integer(attr(attrs, :actor_id)) or is_integer(remote_actor_id(attrs))
  end

  defp source_message_blocked?(user_id, attrs) do
    with source_id when is_integer(source_id) <- attr(attrs, :source_id),
         true <- attr(attrs, :source_type) in ["message", "post", "discussion"],
         %Message{} = message <- load_message(source_id) do
      social_message?(message) and not FeedPolicy.visible_for_notification?(user_id, message)
    else
      _ -> false
    end
  end

  defp source_thread_muted?(user_id, attrs) do
    with source_id when is_integer(source_id) <- attr(attrs, :source_id),
         true <- attr(attrs, :source_type) in ["message", "post", "discussion"],
         %Message{} = message <- load_message(source_id) do
      social_message?(message) and ThreadMutes.muted?(user_id, message)
    else
      _ -> false
    end
  end

  defp load_message(message_id) do
    Message
    |> Repo.get(message_id)
    |> case do
      %Message{} = message -> Repo.preload(message, [:conversation, :remote_actor])
      nil -> nil
    end
  end

  defp social_message?(%Message{conversation: %{type: type}})
       when type in ["dm", "group", "channel"],
       do: false

  defp social_message?(_message), do: true

  defp local_actor_blocked?(_user_id, nil), do: false
  defp local_actor_blocked?(user_id, actor_id) when user_id == actor_id, do: false

  defp local_actor_blocked?(user_id, actor_id) when is_integer(actor_id) do
    Repo.exists?(
      from m in UserMute,
        where: m.muter_id == ^user_id and m.muted_id == ^actor_id
    ) or
      Repo.exists?(
        from b in UserBlock,
          where:
            (b.blocker_id == ^user_id and b.blocked_id == ^actor_id) or
              (b.blocker_id == ^actor_id and b.blocked_id == ^user_id)
      )
  end

  defp local_actor_blocked?(_user_id, _actor_id), do: false

  defp remote_actor_blocked?(_user_id, nil), do: false

  defp remote_actor_blocked?(user_id, remote_actor_id) when is_integer(remote_actor_id) do
    case Repo.get(Actor, remote_actor_id) do
      %Actor{} = actor ->
        blocked_remote_actor?(user_id, actor) or blocked_instance?(actor.domain)

      nil ->
        false
    end
  end

  defp remote_actor_blocked?(_user_id, _remote_actor_id), do: false

  defp blocked_remote_actor?(user_id, %Actor{} = actor) do
    Repo.exists?(
      from b in ActivityPubUserBlock,
        where: b.user_id == ^user_id,
        where:
          (b.block_type in ["user", "mute"] and b.blocked_uri == ^actor.uri) or
            (b.block_type == "domain" and
               (fragment("lower(?)", b.blocked_uri) == fragment("lower(?)", ^actor.domain) or
                  fragment(
                    "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
                    b.blocked_uri,
                    ^actor.domain,
                    b.blocked_uri
                  )))
    )
  end

  defp blocked_instance?(domain) when is_binary(domain) do
    Repo.exists?(
      from i in Instance,
        where: i.blocked == true,
        where:
          fragment("lower(?)", i.domain) == fragment("lower(?)", ^domain) or
            fragment(
              "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
              i.domain,
              ^domain,
              i.domain
            )
    )
  end

  defp blocked_instance?(_domain), do: false

  defp remote_actor_id(attrs) do
    metadata = attr(attrs, :metadata) || %{}
    attr(metadata, :remote_actor_id) || attr(metadata, :activitypub_actor_id)
  end

  defp attr(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
