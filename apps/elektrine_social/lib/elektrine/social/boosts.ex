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
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.PostBoost

  @doc """
  Boosts a post (like Mastodon's reblog/boost).

  Creates a timeline entry showing the boost.

  Returns:
  - `{:ok, boost}` on success
  - `{:error, :empty_post}` if the post has no content or media
  - `{:error, :already_boosted}` if already boosted
  """
  def boost_post(user_id, message_id) do
    # Get original message to validate it has content
    original =
      Repo.get!(Message, message_id) |> Repo.preload([:sender, :conversation, :remote_actor])

    if public_reshareable_message?(original) do
      # Validate: Don't allow boosting empty posts (must have content OR media)
      has_content = Elektrine.Strings.present?(original.content)
      has_media = original.media_urls && original.media_urls != []

      if !has_content && !has_media do
        {:error, :empty_post}
      else
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
              {:ok, _share_post} ->
                # Successfully created boost post
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

          {:error, %Ecto.Changeset{errors: [user_id: {"has already been taken", _}]}} ->
            {:error, :already_boosted}

          error ->
            error
        end
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Unboosts a post.

  Removes the boost and deletes the timeline entry.
  """
  def unboost_post(user_id, message_id) do
    original = Repo.get!(Message, message_id)

    case Repo.get_by(PostBoost, user_id: user_id, message_id: message_id) do
      nil ->
        {:error, :not_boosted}

      boost ->
        case Repo.delete(boost) do
          {:ok, deleted_boost} ->
            reconcile_share_count(original, -1)

            safe_broadcast_share_count_update(message_id)

            # Delete the timeline shared post (if exists)
            from(m in Message,
              where:
                m.sender_id == ^user_id and
                  m.shared_message_id == ^message_id and
                  is_nil(m.deleted_at)
            )
            |> Repo.update_all(set: [deleted_at: Elektrine.Time.utc_now()])

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
    quoted = Repo.get!(Message, quoted_message_id)

    cond do
      not can_quote_message?(quoted, user_id) ->
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
              where: m.id == ^quoted_message_id,
              update: [inc: [quote_count: 1]]
            )
            |> Repo.update_all([])

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

  defp public_reshareable_message?(%Message{visibility: visibility}) do
    visibility in ["public", "unlisted"]
  end

  @doc """
  Checks if a user has boosted a post.
  """
  def user_boosted?(user_id, message_id) do
    from(b in PostBoost,
      where: b.user_id == ^user_id and b.message_id == ^message_id
    )
    |> Repo.exists?()
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

    from(m in Message,
      where: m.id == ^message.id,
      update: [set: [share_count: ^share_count]]
    )
    |> Repo.update_all([])
  end

  defp remote_share_count_baseline(%Message{} = message) do
    message
    |> Map.get(:media_metadata, %{})
    |> Map.get("original_share_count")
    |> parse_non_negative_integer()
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
    message = Repo.get!(Message, message_id)

    Elektrine.Social.Messages.broadcast_post_counts_updated(message_id, %{
      like_count: message.like_count || 0,
      share_count: message.share_count || 0,
      reply_count: message.reply_count || 0
    })
  end
end
