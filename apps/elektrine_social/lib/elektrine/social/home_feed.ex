defmodule Elektrine.Social.HomeFeed do
  @moduledoc """
  Phoenix-native home feed fanout and invalidation boundary.
  """

  import Ecto.Query

  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.{FeedPolicy, HashtagFollow, HomeFeedCache, Message, PostHashtag}

  @topic_prefix "home_feed:"
  @global_topic "home_feed"

  def fanout_message(message_id, opts \\ []) when is_integer(message_id) do
    with %Message{} = message <- load_message(message_id) do
      message
      |> candidate_home_user_ids()
      |> Enum.each(&insert_if_visible(&1, message, opts))
    end

    :ok
  end

  def insert_if_visible(user_id, message_or_id, opts \\ []) when is_integer(user_id) do
    with %Message{} = message <- load_message(message_or_id),
         true <- FeedPolicy.visible_in_home?(user_id, message, opts) do
      HomeFeedCache.add(user_id, message.id)
      emit_fanout_event(:insert, user_id, message.id)
      broadcast(user_id, {:home_feed_inserted, message.id})
      :ok
    else
      _ ->
        remove(user_id, message_id(message_or_id))
    end
  end

  def clear(user_id, reason \\ :policy_changed) when is_integer(user_id) do
    HomeFeedCache.clear(user_id)
    broadcast(user_id, {:home_feed_invalidated, reason})
    :ok
  end

  def clear_all(reason \\ :policy_changed) do
    HomeFeedCache.clear_all()
    ElektrineWeb.Endpoint.broadcast(@global_topic, "home_feed_invalidated", %{reason: reason})
    :ok
  end

  def remove(user_id, message_id) when is_integer(user_id) and is_integer(message_id) do
    HomeFeedCache.delete(user_id, message_id)
    emit_fanout_event(:remove, user_id, message_id)
    broadcast(user_id, {:home_feed_removed, message_id})
    :ok
  end

  def remove(_user_id, _message_id), do: :ok

  def message_deleted(%Message{} = message) do
    message
    |> candidate_home_user_ids()
    |> Enum.each(&remove(&1, message.id))

    :ok
  end

  def message_changed(%Message{} = message) do
    message
    |> candidate_home_user_ids()
    |> Enum.each(fn user_id ->
      if FeedPolicy.visible_in_home?(user_id, message) do
        insert_if_visible(user_id, message)
      else
        remove(user_id, message.id)
      end
    end)

    :ok
  end

  def actor_policy_changed(user_id) when is_integer(user_id),
    do: clear(user_id, :actor_policy_changed)

  def candidate_home_user_ids(%Message{} = message) do
    message
    |> local_candidate_home_user_ids()
    |> Kernel.++(remote_candidate_home_user_ids(message))
    |> Kernel.++(hashtag_candidate_home_user_ids(message))
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  def candidate_home_user_ids(_message), do: []

  defp local_candidate_home_user_ids(%Message{sender_id: sender_id}) when is_integer(sender_id) do
    follower_ids =
      Repo.all(
        from f in Follow,
          where: f.followed_id == ^sender_id and f.pending == false,
          select: f.follower_id
      )

    [sender_id | follower_ids]
  end

  defp local_candidate_home_user_ids(_message), do: []

  defp remote_candidate_home_user_ids(%Message{remote_actor_id: actor_id})
       when is_integer(actor_id) do
    Repo.all(
      from f in Follow,
        where: f.remote_actor_id == ^actor_id and f.pending == false,
        select: f.follower_id
    )
  end

  defp remote_candidate_home_user_ids(_message), do: []

  defp hashtag_candidate_home_user_ids(%Message{id: message_id}) when is_integer(message_id) do
    Repo.all(
      from ph in PostHashtag,
        join: hf in HashtagFollow,
        on: hf.hashtag_id == ph.hashtag_id,
        where: ph.message_id == ^message_id,
        select: hf.user_id
    )
  end

  defp hashtag_candidate_home_user_ids(_message), do: []

  defp load_message(%Message{} = message), do: Repo.preload(message, [:remote_actor])

  defp load_message(message_id) when is_integer(message_id) do
    Message
    |> Repo.get(message_id)
    |> case do
      %Message{} = message -> Repo.preload(message, [:remote_actor])
      nil -> nil
    end
  end

  defp load_message(_message), do: nil

  defp message_id(%Message{id: id}), do: id
  defp message_id(id) when is_integer(id), do: id
  defp message_id(_), do: nil

  defp broadcast(user_id, event) do
    ElektrineWeb.Endpoint.broadcast(@topic_prefix <> Integer.to_string(user_id), "home_feed", %{
      event: event
    })
  end

  defp emit_fanout_event(operation, user_id, message_id) do
    :telemetry.execute(
      [:elektrine, :home_feed, :fanout],
      %{count: 1},
      %{operation: operation, user_id: user_id, message_id: message_id}
    )

    :ok
  rescue
    _ -> :ok
  end
end
