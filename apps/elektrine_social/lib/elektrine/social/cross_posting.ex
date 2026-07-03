defmodule Elektrine.Social.CrossPosting do
  @moduledoc """
  Cross-context promotion and sharing between chat, discussions, and the timeline.
  """

  import Ecto.Query, warn: false

  alias Elektrine.ActivityPub.Outbox
  alias Elektrine.Async
  alias Elektrine.Messaging
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  @doc """
  Promotes a chat message to timeline as a public post.
  This enables the natural progression from private insights to public sharing.
  """
  def promote_message_to_timeline(message_id, user_id, opts \\ []) do
    # Check cross-context promotion rate limit
    if RateLimiter.can_promote_cross_context?(user_id) do
      visibility = Keyword.get(opts, :visibility, "public")

      # Get the original message
      message =
        from(m in Message,
          where: m.id == ^message_id and m.sender_id == ^user_id,
          preload: [:sender, :conversation]
        )
        |> Repo.one()

      promote_message_to_timeline_post(message, user_id, visibility)
    else
      {:error, :rate_limited}
    end
  end

  defp promote_message_to_timeline_post(nil, _user_id, _visibility), do: {:error, :not_found}

  defp promote_message_to_timeline_post(%Message{deleted_at: deleted_at}, _user_id, _visibility)
       when not is_nil(deleted_at),
       do: {:error, :message_deleted}

  defp promote_message_to_timeline_post(%Message{} = msg, user_id, visibility) do
    content_with_hash = timeline_promotion_content(msg)

    case Elektrine.Social.create_timeline_post(user_id, content_with_hash,
           visibility: visibility,
           original_message_id: msg.id,
           promoted_from: "chat"
         ) do
      {:ok, timeline_post} ->
        RateLimiter.record_cross_promotion(user_id)
        {:ok, timeline_post}

      error ->
        error
    end
  end

  defp timeline_promotion_content(msg) do
    content = String.trim(msg.content)

    case msg.conversation.hash do
      nil -> content
      hash -> "#{content}\n\n<!-- hash:#{hash} name:#{msg.conversation.name} -->"
    end
  end

  @doc """
  Unified cross-posting function for sharing content between platforms.
  Supports sharing from timeline, discussions, and chat to any other platform.
  """
  def cross_post_to_discussion(source_message_id, user_id, community_id, title, comment \\ "") do
    case fetch_cross_post_source(source_message_id) do
      nil ->
        {:error, :not_found}

      %Message{} = source ->
        with :ok <- ensure_conversation_member(community_id, user_id),
             {:ok, discussion_message} <-
               Messaging.create_text_message(community_id, user_id, comment || "") do
          discussion_message
          |> Message.changeset(%{
            post_type: "discussion",
            title: title,
            shared_message_id: source_message_id,
            share_type: "cross_post",
            promoted_from: get_source_type(source),
            metadata: %{
              "title" => title,
              "cross_post_source" => %{
                "id" => source.id,
                "type" => get_source_type(source),
                "name" => get_source_name(source)
              }
            }
          })
          |> Repo.update()
        else
          {:error, :not_member} -> {:error, :not_member}
          error -> error
        end
    end
  end

  defp fetch_cross_post_source(source_message_id) do
    from(m in Message,
      where: m.id == ^source_message_id,
      preload: [:sender, :conversation, :link_preview]
    )
    |> Repo.one()
  end

  defp ensure_conversation_member(conversation_id, user_id) do
    case Messaging.get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :not_member}
      _member -> :ok
    end
  end

  defp get_source_type(%Message{conversation: %{type: "timeline"}}), do: "timeline"
  defp get_source_type(%Message{conversation: %{type: "community"}}), do: "discussion"
  defp get_source_type(%Message{conversation: %{type: "dm"}}), do: "chat"
  defp get_source_type(%Message{conversation: %{type: "group"}}), do: "chat"
  defp get_source_type(%Message{conversation: %{type: "channel"}}), do: "chat"
  defp get_source_type(_), do: "unknown"

  defp get_source_name(%Message{conversation: %{type: "timeline"}}), do: "Timeline"
  defp get_source_name(%Message{conversation: %{type: "community", name: name}}), do: name
  defp get_source_name(%Message{conversation: %{type: "dm"}}), do: "Chat"
  defp get_source_name(%Message{conversation: %{type: "group"}}), do: "Chat"
  defp get_source_name(%Message{conversation: %{type: "channel"}}), do: "Chat"
  defp get_source_name(_), do: ""

  @doc """
  Cross-post content to a chat conversation
  """
  def cross_post_to_chat(source_message_id, user_id, conversation_id, comment \\ "") do
    source_message =
      from(m in Message, where: m.id == ^source_message_id, preload: [:sender, :conversation])
      |> Repo.one()

    case source_message do
      nil ->
        {:error, :not_found}

      %Message{} = source ->
        message_content = minimal_share_comment(comment)

        case Messaging.create_text_message(conversation_id, user_id, message_content) do
          {:ok, message} ->
            message
            |> Message.changeset(%{
              shared_message_id: source_message_id,
              share_type: "cross_post",
              promoted_from: get_source_type(source)
            })
            |> Repo.update()

          error ->
            error
        end
    end
  end

  defp minimal_share_comment(comment) when comment in ["", nil], do: " "
  defp minimal_share_comment(comment), do: comment

  @doc """
  Promotes a timeline post to a community discussion.
  This enables moving viral content to deeper discussion contexts.
  """
  def promote_timeline_to_discussion(message_id, user_id, community_id, opts \\ []) do
    discussion_title = Keyword.get(opts, :title)

    # Get the original timeline post
    timeline_post =
      from(m in Message,
        where: m.id == ^message_id and m.post_type == "post",
        preload: [:sender, :conversation, :link_preview]
      )
      |> Repo.one()

    case timeline_post do
      nil ->
        {:error, :not_found}

      %Message{} = post ->
        with :ok <- ensure_conversation_member(community_id, user_id),
             {:ok, discussion_message} <- Messaging.create_text_message(community_id, user_id, "") do
          title = discussion_title || "Discussion: #{String.slice(post.content, 0, 50)}..."

          discussion_message
          |> Message.changeset(%{
            post_type: "discussion",
            shared_message_id: post.id,
            share_type: "cross_post",
            promoted_from: "timeline",
            title: title
          })
          |> Repo.update()
        else
          {:error, :not_member} -> {:error, :not_member}
          error -> error
        end
    end
  end

  @doc """
  Creates a private DM conversation from public content for deeper discussion.
  This enables moving public conversations to private contexts.
  """
  def discuss_privately(message_id, initiator_user_id, target_user_id, opts \\ []) do
    intro_message =
      Keyword.get(opts, :intro_message, "Hey, saw your post and wanted to discuss this further!")

    # Get the original message for context
    original_message =
      from(m in Message,
        where: m.id == ^message_id,
        preload: [:sender, :conversation]
      )
      |> Repo.one()

    case original_message do
      nil ->
        {:error, :not_found}

      %Message{} = msg ->
        with {:ok, dm_conversation} <-
               Messaging.create_dm_conversation(initiator_user_id, target_user_id),
             {:ok, dm_message} <-
               Messaging.create_text_message(dm_conversation.id, initiator_user_id, intro_message) do
          dm_message
          |> Message.changeset(%{
            shared_message_id: message_id,
            share_type: "cross_post",
            promoted_from: get_source_type(msg)
          })
          |> Repo.update()
        else
          error -> error
        end
    end
  end

  @doc """
  Shares content from one context to timeline with proper attribution.
  Generic function for cross-context sharing.
  """
  def share_to_timeline(source_message_id, user_id, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, "followers")
    comment = Keyword.get(opts, :comment, "")

    # Get source message
    source =
      from(m in Message,
        where: m.id == ^source_message_id,
        preload: [:sender, :conversation, :remote_actor]
      )
      |> Repo.one()

    case source do
      nil ->
        {:error, :not_found}

      %Message{} = msg ->
        result =
          Elektrine.Social.create_timeline_post(
            user_id,
            comment || "",
            Keyword.merge(
              [
                visibility: visibility,
                shared_message_id: msg.id,
                share_type: share_type_for_message(msg),
                promoted_from: promoted_from_for_message(msg)
              ],
              share_extra_attrs(msg)
            )
          )

        maybe_federate_announce_share(result, msg, user_id)
    end
  end

  defp share_type_for_message(%Message{federated: true}), do: "federated_boost"
  defp share_type_for_message(msg), do: determine_share_type(msg)

  defp promoted_from_for_message(%Message{federated: true}), do: "fediverse"
  defp promoted_from_for_message(msg), do: determine_promoted_from(msg)

  defp share_extra_attrs(%Message{conversation: %{type: "community", hash: hash, name: name}})
       when is_binary(hash) do
    [promoted_from_community_hash: hash, promoted_from_community_name: name]
  end

  defp share_extra_attrs(_), do: []

  defp maybe_federate_announce_share({:ok, _share_post} = result, %Message{} = msg, user_id) do
    if msg.federated && msg.activitypub_id do
      Async.start(fn ->
        Outbox.federate_announce(msg.id, user_id)
      end)
    end

    result
  end

  defp maybe_federate_announce_share(error, _msg, _user_id), do: error

  @doc """
  Links a discussion post to a timeline post for unified commenting.
  This enables shared comment threads across contexts.
  """
  def link_discussion_to_timeline(discussion_id, timeline_post_id, user_id) do
    # Get both posts
    with {:ok, discussion} <- get_message(discussion_id),
         {:ok, timeline_post} <- get_message(timeline_post_id),
         true <- discussion.sender_id == user_id || timeline_post.sender_id == user_id do
      # Link discussion as a "promotion" of the timeline post
      discussion
      |> Message.changeset(%{
        original_message_id: timeline_post_id,
        promoted_from: "timeline"
      })
      |> Repo.update()
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc """
  Gets unified replies for a post across all contexts.
  """
  def get_unified_replies(post_id) do
    from(m in Message,
      where:
        m.reply_to_id == ^post_id and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      order_by: [desc: m.like_count, desc: m.score, asc: m.inserted_at],
      preload: [sender: [:profile], conversation: []]
    )
    |> Repo.all()
  end

  defp get_message(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  # Private helper functions for content promotion

  defp determine_share_type(%Message{conversation: %{type: "community"}}), do: "discussion_share"
  defp determine_share_type(%Message{post_type: "post"}), do: "timeline_reshare"
  defp determine_share_type(_), do: "general_share"

  defp determine_promoted_from(%Message{conversation: %{type: "community"}}), do: "discussion"
  defp determine_promoted_from(%Message{conversation: %{type: "timeline"}}), do: "timeline"
  defp determine_promoted_from(%Message{promoted_from: "timeline_reply"}), do: "timeline"
  defp determine_promoted_from(%Message{post_type: "post"}), do: "timeline"
  defp determine_promoted_from(%Message{conversation: %{type: "dm"}}), do: "chat"
  defp determine_promoted_from(%Message{conversation: %{type: "group"}}), do: "chat"
  defp determine_promoted_from(%Message{conversation: %{type: "channel"}}), do: "chat"
  defp determine_promoted_from(_), do: "chat"
end
