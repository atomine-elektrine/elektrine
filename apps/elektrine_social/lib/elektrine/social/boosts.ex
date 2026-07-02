defmodule Elektrine.Social.Boosts do
  @moduledoc """
  Handles post boosts (reblogs) and quote posts.

  Boosts are similar to Mastodon's reblog or Twitter's retweet:
  - They share another user's post to your followers
  - They create a visible entry on your timeline
  - They federate to ActivityPub as Announce activities

  Quote posts allow adding commentary while sharing.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.AppCache
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.MessagePolicy
  alias Elektrine.Social.MessageStats
  alias Elektrine.Social.PostBoost

  @doc """
  Boosts a post (like Mastodon's reblog/boost).

  Creates a timeline entry showing the boost.

  Returns:
  - `{:ok, boost}` on success
  - `{:error, :empty_post}` if the post has no content or media
  - already boosted posts return the existing boost
  """
  def boost_post(user_id, message_id) do
    # Get original message to validate it has content
    original =
      get_message!(message_id) |> Repo.preload([:sender, :conversation, :remote_actor])

    if MessagePolicy.boost?(user_id, original) && public_reshareable_message?(original) do
      # Validate: Don't allow boosting empty posts (must have content OR media)
      has_content = Elektrine.Strings.present?(original.content)
      has_media = original.media_urls && original.media_urls != []

      if !has_content && !has_media do
        {:error, :empty_post}
      else
        case Repo.get_by(PostBoost, user_id: user_id, message_id: message_id) do
          %PostBoost{} = boost ->
            {:ok, boost}

          nil ->
            insert_boost(user_id, message_id, original)
        end
      end
    else
      {:error, :not_found}
    end
  end

  defp insert_boost(user_id, message_id, original) do
    %PostBoost{}
    |> PostBoost.changeset(%{
      user_id: user_id,
      message_id: message_id
    })
    |> Repo.insert()
    |> case do
      {:ok, boost} ->
        reconcile_share_count(original, 1)

        safe_broadcast_share_count_update(message_id)

        # Create boost as a shared post on timeline
        case Elektrine.Social.share_to_timeline(message_id, user_id,
               visibility: "public",
               comment: ""
             ) do
          {:ok, share_post} ->
            # Successfully created boost post
            _ = Elektrine.Social.HomeFeedFanoutWorker.enqueue(share_post.id)
            :ok

          {:error, reason} ->
            # Log error but don't fail the boost
            Logger.error("Failed to create boost timeline entry: #{inspect(reason)}")
            :ok
        end

        # Federate the boost
        Elektrine.Async.run(fn ->
          Elektrine.ActivityPub.Outbox.federate_announce(message_id, user_id)
          _ = Elektrine.Bluesky.OutboundWorker.enqueue_repost(message_id, user_id)
        end)

        {:ok, boost}

      {:error, %Ecto.Changeset{}} = error ->
        case Repo.get_by(PostBoost, user_id: user_id, message_id: message_id) do
          %PostBoost{} = boost -> {:ok, boost}
          nil -> error
        end

      error ->
        error
    end
  end

  @doc """
  Unboosts a post.

  Removes the boost and deletes the timeline entry.
  """
  def unboost_post(user_id, message_id) do
    original = get_message!(message_id)

    case Repo.get_by(PostBoost, user_id: user_id, message_id: message_id) do
      nil ->
        {:ok, nil}

      boost ->
        case Repo.delete(boost) do
          {:ok, deleted_boost} ->
            reconcile_share_count(original, -1)

            safe_broadcast_share_count_update(message_id)

            # Delete the timeline shared post (if exists)
            share_post_ids =
              from(m in Message,
                where:
                  m.sender_id == ^user_id and
                    m.shared_message_id == ^message_id and
                    is_nil(m.deleted_at),
                select: m.id
              )
              |> Repo.all()

            from(m in Message,
              where:
                m.sender_id == ^user_id and
                  m.shared_message_id == ^message_id and
                  is_nil(m.deleted_at)
            )
            |> Repo.update_all(set: [deleted_at: Elektrine.Time.utc_now()])

            Enum.each(share_post_ids, fn share_post_id ->
              _ = Elektrine.Social.HomeFeedInvalidationWorker.remove_message(share_post_id)
            end)

            # Federate the unboost (Undo Announce)
            Elektrine.Async.run(fn ->
              user = Elektrine.Accounts.get_user!(user_id)
              message = Elektrine.Messaging.get_message(message_id)

              if message && message.activitypub_id && user.activitypub_enabled do
                announce_activity =
                  Elektrine.ActivityPub.Builder.build_announce_activity(
                    user,
                    message.activitypub_id
                  )

                undo_activity =
                  Elektrine.ActivityPub.Builder.build_undo_activity(user, announce_activity)

                inbox_urls = Elektrine.ActivityPub.Publisher.get_follower_inboxes(user.id)

                if inbox_urls != [] do
                  Elektrine.ActivityPub.Publisher.publish(undo_activity, user, inbox_urls)
                end
              end

              _ = Elektrine.Bluesky.OutboundWorker.enqueue_unrepost(message_id, user_id)
            end)

            {:ok, deleted_boost}

          error ->
            error
        end
    end
  end

  @doc """
  Creates a quote post - a post that quotes another post with commentary.

  This is similar to a retweet with comment or Mastodon's quote posts.

  Returns:
  - `{:ok, quote_post}` on success
  - `{:error, :empty_quote}` if content is empty
  """
  def create_quote_post(user_id, quoted_message_id, content, opts \\ []) do
    # Validate the quoted message exists
    quoted = get_message!(quoted_message_id)

    cond do
      not MessagePolicy.quote?(user_id, quoted) or not can_quote_message?(quoted, user_id) ->
        {:error, :not_found}

      not Elektrine.Strings.present?(content) ->
        {:error, :empty_quote}

      true ->
        visibility = Keyword.get(opts, :visibility, "public")

        # Get or create user's timeline conversation (same as regular posts)
        timeline_conversation = Elektrine.Social.get_or_create_user_timeline(user_id)

        # Create the quote post (use "post" type since "quote" isn't in DB constraint)
        quote_attrs = %{
          content: content,
          sender_id: user_id,
          quoted_message_id: quoted_message_id,
          visibility: visibility,
          post_type: "post",
          public: visibility in ["public", "unlisted"],
          conversation_id: timeline_conversation.id
        }

        case Message.changeset(%Message{}, quote_attrs) |> Repo.insert() do
          {:ok, quote_post} ->
            # Increment quote count on the quoted message
            from(m in Message,
              where: m.id == ^quoted_message_id and is_nil(m.deleted_at),
              update: [inc: [quote_count: 1]]
            )
            |> Repo.update_all([])

            AppCache.invalidate_social_message(quoted_message_id)

            MessageStats.upsert_counts(quoted_message_id, %{
              quote_count: quote_count(quoted_message_id)
            })

            # Federate the quote post if user has federation enabled
            Elektrine.Async.run(fn ->
              user = Elektrine.Accounts.get_user!(user_id)

              if user.activitypub_enabled do
                # Reload with associations for federation
                reloaded =
                  Repo.get!(Message, quote_post.id)
                  |> Repo.preload([:sender, :quoted_message])

                Elektrine.ActivityPub.Outbox.federate_post(reloaded)
              end
            end)

            {:ok, quote_post}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp can_quote_message?(quoted_message, user_id) do
    case quoted_message.visibility do
      "public" -> true
      "unlisted" -> true
      "followers" -> false
      "friends" -> false
      "private" -> quoted_message.sender_id == user_id
      _ -> false
    end
  end

  defp public_reshareable_message?(%Message{visibility: visibility, deleted_at: nil}) do
    visibility in ["public", "unlisted"]
  end

  defp public_reshareable_message?(_), do: false

  @doc """
  Checks if a user has boosted a post.
  """
  def user_boosted?(user_id, message_id) do
    from(b in PostBoost,
      where: b.user_id == ^user_id and b.message_id == ^message_id
    )
    |> Repo.exists?()
  end

  @doc """
  Returns the message IDs boosted by a user from a candidate list.
  """
  def list_user_boosts(user_id, message_ids) when is_list(message_ids) do
    from(b in PostBoost,
      where: b.user_id == ^user_id and b.message_id in ^message_ids,
      select: b.message_id
    )
    |> Repo.all()
  end

  defp safe_broadcast_share_count_update(message_id) do
    broadcast_share_count_update(message_id)
  rescue
    error ->
      Logger.warning(
        "Failed to broadcast share count update for #{inspect(message_id)}: #{Exception.message(error)}"
      )

      :ok
  end

  defp reconcile_share_count(%Message{} = message, delta) when delta in [-1, 1] do
    message = Repo.get!(Message, message.id)

    current_local_boost_count =
      from(b in PostBoost,
        where: b.message_id == ^message.id,
        select: count(b.id)
      )
      |> Repo.one()

    previous_local_boost_count = max(current_local_boost_count - delta, 0)

    remote_baseline =
      message
      |> remote_share_count_baseline()
      |> max(max((message.share_count || 0) - previous_local_boost_count, 0))

    share_count = remote_baseline + current_local_boost_count

    result =
      from(m in Message,
        where: m.id == ^message.id,
        update: [set: [share_count: ^share_count]]
      )
      |> Repo.update_all([])

    AppCache.invalidate_social_message(message.id)
    MessageStats.upsert_counts(message.id, %{share_count: share_count})
    result
  end

  defp remote_share_count_baseline(%Message{} = message) do
    remote_count =
      message
      |> Map.get(:remote_share_count)
      |> parse_non_negative_integer()

    metadata_count =
      message
      |> Map.get(:media_metadata, %{})
      |> Map.get("original_share_count")
      |> parse_non_negative_integer()

    max(remote_count, metadata_count)
  end

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_non_negative_integer(_), do: 0

  defp broadcast_share_count_update(message_id) do
    message = get_message!(message_id)

    Elektrine.Social.Messages.broadcast_post_counts_updated(message_id, %{
      like_count: message.like_count || 0,
      share_count: message.share_count || 0,
      reply_count: message.reply_count || 0
    })
  end

  defp quote_count(message_id) do
    from(m in Message, where: m.id == ^message_id, select: coalesce(m.quote_count, 0))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp get_message!(message_id) do
    case AppCache.get_social_message(message_id, fn -> Repo.get(Message, message_id) end) do
      %Message{} = message -> message
      _ -> Repo.get!(Message, message_id)
    end
  end
end
