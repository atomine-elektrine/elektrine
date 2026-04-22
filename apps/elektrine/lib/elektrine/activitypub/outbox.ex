defmodule Elektrine.ActivityPub.Outbox do
  @moduledoc """
  Handles outgoing ActivityPub activities.
  Publishes local user actions to remote followers.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Fetcher, Mentions, Publisher}
  alias Elektrine.Bluesky.OutboundWorker
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @doc """
  Federates a newly created message/post to remote followers.
  Called automatically when a user creates a public or followers-only post.
  """
  def federate_post(%Message{} = message) do
    maybe_federate_activitypub(message)
    maybe_federate_bluesky(message)
    :ok
  end

  defp maybe_federate_activitypub(%Message{} = message) do
    with true <- federatable_post?(message),
         %{} = user <- activitypub_user(message.sender_id) do
      poll = maybe_poll_for_message(message)
      create_activity = build_post_create_activity(message, user, poll)
      maybe_set_message_activitypub_id(message, create_activity["object"]["id"])
      community_uri = get_community_uri_from_chain(message)
      inbox_urls = fanout_inboxes_for_post(message, user.id)

      Logger.debug(
        "Federating post #{message.id}: " <>
          "base=#{length(base_post_inboxes(message, user.id))}, " <>
          "mentions=#{length(mention_inboxes_for_message(message))}, " <>
          "relays=#{length(relay_inboxes_for_visibility(message.visibility))}, " <>
          "community=#{length(community_inboxes_for_uri(community_uri))}, " <>
          "total=#{length(inbox_urls)}, community_uri=#{inspect(community_uri)}"
      )

      publish_post_activity(message, create_activity, user, inbox_urls)
    end

    :ok
  end

  defp maybe_federate_bluesky(%Message{} = message) do
    _ = OutboundWorker.enqueue_mirror_post(message.id)
    :ok
  end

  defp federatable_post?(%Message{visibility: visibility, sender_id: sender_id}) do
    visibility in ["public", "followers"] and not is_nil(sender_id)
  end

  defp activitypub_user(sender_id) when not is_nil(sender_id) do
    user = Accounts.get_user!(sender_id)
    if user.activitypub_enabled, do: user, else: nil
  end

  defp activitypub_user(_), do: nil

  defp maybe_poll_for_message(%Message{post_type: "poll", id: message_id}) do
    case poll_schema() do
      nil ->
        nil

      poll_schema ->
        Repo.get_by(poll_schema, message_id: message_id)
        |> Repo.preload(:options)
    end
  end

  defp maybe_poll_for_message(_), do: nil

  defp poll_schema do
    if Code.ensure_loaded?(Elektrine.Social.Poll), do: Elektrine.Social.Poll, else: nil
  end

  defp build_post_create_activity(message, user, nil),
    do: Builder.build_create_activity(message, user)

  defp build_post_create_activity(message, user, poll) do
    question = Builder.build_question(message, user, poll)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{question["id"]}/activity",
      "type" => "Create",
      "actor" => ActivityPub.actor_uri(user),
      "published" => Builder.format_datetime(message.inserted_at),
      "to" => question["to"],
      "cc" => question["cc"],
      "object" => question
    }
  end

  defp maybe_set_message_activitypub_id(%Message{activitypub_id: nil} = message, object_id) do
    Elektrine.Messaging.update_message(message, %{
      activitypub_id: object_id,
      activitypub_url: object_id
    })
  end

  defp maybe_set_message_activitypub_id(_message, _object_id), do: :ok

  defp base_post_inboxes(%Message{reply_to_id: nil}, user_id),
    do: Publisher.get_follower_inboxes(user_id)

  defp base_post_inboxes(message, user_id), do: get_reply_inboxes(message, user_id)

  defp mention_inboxes_for_message(%Message{content: content}) when is_binary(content),
    do: Mentions.get_mention_inboxes(content)

  defp mention_inboxes_for_message(_), do: []

  defp relay_inboxes_for_visibility("public"), do: ActivityPub.get_relay_inboxes()
  defp relay_inboxes_for_visibility(_), do: []

  defp community_inboxes_for_uri(nil), do: []

  defp community_inboxes_for_uri(uri) do
    case ActivityPub.get_actor_by_uri(uri) do
      nil ->
        fetch_community_inboxes(uri)

      %{inbox_url: inbox_url} ->
        maybe_single_inbox(inbox_url)
    end
  end

  defp fetch_community_inboxes(uri) do
    case Fetcher.fetch_actor(uri) do
      {:ok, actor_data} ->
        inbox = get_in(actor_data, ["endpoints", "sharedInbox"]) || actor_data["inbox"]
        maybe_single_inbox(inbox)

      _ ->
        []
    end
  end

  defp maybe_single_inbox(inbox_url) when is_binary(inbox_url), do: [inbox_url]
  defp maybe_single_inbox(_), do: []

  defp fanout_inboxes_for_post(message, user_id) do
    base_inboxes = base_post_inboxes(message, user_id)
    mention_inboxes = mention_inboxes_for_message(message)
    relay_inboxes = relay_inboxes_for_visibility(message.visibility)
    community_uri = get_community_uri_from_chain(message)
    community_inboxes = community_inboxes_for_uri(community_uri)

    (base_inboxes ++ mention_inboxes ++ relay_inboxes ++ community_inboxes)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp publish_post_activity(message, _create_activity, _user, []),
    do: Logger.warning("No inboxes to send post #{message.id} to")

  defp publish_post_activity(_message, create_activity, user, inbox_urls),
    do: Publisher.publish(create_activity, user, inbox_urls)

  defp maybe_publish(_activity, _user, []), do: :ok

  defp maybe_publish(activity, user, inbox_urls),
    do: Publisher.publish(activity, user, inbox_urls)

  defp get_reply_inboxes(message, user_id) do
    # Get the parent message
    parent = Elektrine.Messaging.get_message(message.reply_to_id)

    base_inboxes = Publisher.get_follower_inboxes(user_id)

    if parent && parent.federated && parent.remote_actor_id do
      # Parent is a federated post - send to remote author
      remote_actor = Elektrine.Repo.get(ActivityPub.Actor, parent.remote_actor_id)

      if remote_actor do
        # Include remote author's inbox (prefer shared inbox for Lemmy/large instances)
        # Shared inbox is stored in metadata.endpoints.sharedInbox, not as a direct field
        shared_inbox = get_in(remote_actor.metadata || %{}, ["endpoints", "sharedInbox"])
        author_inbox = shared_inbox || remote_actor.inbox_url

        inboxes = [author_inbox | base_inboxes]

        Enum.uniq(Enum.reject(inboxes, &is_nil/1))
      else
        Logger.warning("Remote actor not found for federated parent")
        base_inboxes
      end
    else
      base_inboxes
    end
  end

  # Walk up the reply chain to find community_actor_uri (for Lemmy posts)
  # This ensures replies to replies in a Lemmy thread still get sent to the community
  defp get_community_uri_from_chain(message, depth \\ 0)

  defp get_community_uri_from_chain(_message, depth) when depth > 10 do
    # Prevent infinite loops - max 10 levels deep
    nil
  end

  defp get_community_uri_from_chain(message, depth) do
    # Check current message's metadata
    case get_in(message.media_metadata || %{}, ["community_actor_uri"]) do
      uri when is_binary(uri) ->
        uri

      nil ->
        with reply_to_id when not is_nil(reply_to_id) <- message.reply_to_id,
             %{} = parent <- Elektrine.Messaging.get_message(reply_to_id) do
          get_community_uri_from_chain(parent, depth + 1)
        else
          _ -> nil
        end
    end
  end

  @doc """
  Sends an Undo Like activity.
  """
  def federate_unlike(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      like_activity =
        latest_local_activity_data(user.id, "Like", message.activitypub_id) ||
          maybe_add_remote_author_audience(
            message,
            Builder.build_like_activity(user, message.activitypub_id)
          )

      # Build Undo activity
      undo_activity = Builder.build_undo_activity(user, like_activity)

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(undo_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends a Like activity to the original author.
  """
  def federate_like(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      # Build Like activity
      like_activity =
        maybe_add_remote_author_audience(
          message,
          Builder.build_like_activity(user, message.activitypub_id)
        )

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(like_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends a Dislike activity (downvote) to the original author.
  """
  def federate_dislike(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      # Build Dislike activity
      dislike_activity =
        maybe_add_remote_author_audience(
          message,
          Builder.build_dislike_activity(user, message.activitypub_id)
        )

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(dislike_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends an Undo Dislike activity.
  """
  def federate_undo_dislike(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      dislike_activity =
        latest_local_activity_data(user.id, "Dislike", message.activitypub_id) ||
          maybe_add_remote_author_audience(
            message,
            Builder.build_dislike_activity(user, message.activitypub_id)
          )

      # Build Undo activity
      undo_activity = Builder.build_undo_activity(user, dislike_activity)

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(undo_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends an Announce (boost/share) activity.
  """
  def federate_announce(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      # Build Announce activity
      announce_activity = Builder.build_announce_activity(user, message.activitypub_id)

      # Send to user's followers
      follower_inboxes = Publisher.get_follower_inboxes(user.id)

      # If boosting a federated post, also send to the original author
      author_inbox = maybe_remote_author_inbox(message)

      inbox_urls = (follower_inboxes ++ author_inbox) |> Enum.uniq()

      if inbox_urls != [] do
        Publisher.publish(announce_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends an Undo Announce (unboost) activity.
  """
  def federate_undo_announce(message_id, user_id) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      announce_activity =
        latest_local_activity_data(user.id, "Announce", message.activitypub_id) ||
          Builder.build_announce_activity(user, message.activitypub_id)

      # Build Undo activity
      undo_activity = Builder.build_undo_activity(user, announce_activity)

      # Send to user's followers
      follower_inboxes = Publisher.get_follower_inboxes(user.id)

      # If unboosting a federated post, also send to the original author
      author_inbox = maybe_remote_author_inbox(message)

      inbox_urls = (follower_inboxes ++ author_inbox) |> Enum.uniq()

      if inbox_urls != [] do
        Publisher.publish(undo_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends an EmojiReact activity for emoji reactions.
  Supports both Unicode emoji and custom emoji (with URL in tag).
  """
  def federate_emoji_react(message_id, user_id, emoji, emoji_url \\ nil) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      base_url = ActivityPub.instance_url()
      activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

      # Build EmojiReact activity
      emoji_react_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => activity_id,
        "type" => "EmojiReact",
        "actor" => ActivityPub.actor_uri(user, base_url),
        "object" => message.activitypub_id,
        "content" => emoji
      }

      # Add custom emoji tag if URL is provided (Akkoma/Pleroma format)
      emoji_react_activity =
        if emoji_url do
          Map.put(emoji_react_activity, "tag", [
            %{
              "type" => "Emoji",
              "name" => emoji,
              "icon" => %{
                "type" => "Image",
                "url" => emoji_url
              }
            }
          ])
        else
          emoji_react_activity
        end

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(emoji_react_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends an Undo EmojiReact activity.
  """
  def federate_undo_emoji_react(message_id, user_id, emoji) do
    message = Elektrine.Messaging.get_message(message_id)
    user = Accounts.get_user!(user_id)

    if message && message.activitypub_id && user.activitypub_enabled do
      emoji_react_activity =
        latest_local_activity_data(user.id, "EmojiReact", message.activitypub_id, content: emoji) ||
          Builder.build_emoji_react_activity(user, message.activitypub_id, emoji)

      # Build Undo activity
      undo_activity = Builder.build_undo_activity(user, emoji_react_activity)

      inbox_urls = target_inboxes_for_message(message)

      if inbox_urls != [] do
        Publisher.publish(undo_activity, user, inbox_urls)
      end
    end

    :ok
  end

  @doc """
  Sends a Delete activity when a message is deleted.
  """
  def federate_delete(%Message{} = message) do
    case local_public_community(message) do
      {:ok, community} -> federate_local_community_delete(message, community)
      :error -> federate_user_delete(message)
    end

    :ok
  end

  @doc """
  Sends an Update activity when a message is edited.
  """
  def federate_update(%Message{} = message) do
    case local_public_community(message) do
      {:ok, community} -> federate_local_community_update(message, community)
      :error -> federate_user_update(message)
    end

    :ok
  end

  @doc """
  Sends an Update activity when user updates their profile.
  """
  def federate_profile_update(user_id) do
    user = Accounts.get_user!(user_id)

    if user.activitypub_enabled do
      # Keep exported actor fields in sync with the profile shown over HTTP.
      user = Elektrine.Repo.preload(user, profile: :links)

      # Build updated actor
      actor = Builder.build_actor(user)

      # Build Update activity
      update_activity = Builder.build_update_activity(user, actor)

      # Send to all followers
      inbox_urls = Publisher.get_follower_inboxes(user.id)

      if inbox_urls != [] do
        Publisher.publish(update_activity, user, inbox_urls)
      end
    end

    :ok
  end

  defp build_post_object(message, user) do
    case maybe_poll_for_message(message) do
      %{options: _} = poll -> Builder.build_question(message, user, poll)
      _ -> Builder.build_note(message, user)
    end
  end

  defp build_community_post_object(message, community, author_uri) do
    Builder.build_community_object(message, community,
      poll: maybe_poll_for_message(message),
      author_uri: author_uri
    )
  end

  defp update_delete_inboxes(message, user_id, create_activity) do
    case delivery_inboxes_for_activity(create_activity) do
      [] -> fanout_inboxes_for_post(message, user_id)
      inboxes -> inboxes
    end
  end

  defp community_update_delete_inboxes(message, community_actor_id, create_activity) do
    case delivery_inboxes_for_activity(create_activity) do
      [] -> community_post_inboxes(message, community_actor_id)
      inboxes -> inboxes
    end
  end

  defp delivery_inboxes_for_activity(nil), do: []

  defp delivery_inboxes_for_activity(%ActivityPub.Activity{id: activity_id}) do
    from(d in ActivityPub.Delivery,
      where: d.activity_id == ^activity_id,
      select: d.inbox_url
    )
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp latest_local_create_activity(%Message{activitypub_id: activitypub_id}, user_id)
       when is_binary(activitypub_id) and not is_nil(user_id) do
    from(a in ActivityPub.Activity,
      where:
        a.local == true and
          a.internal_user_id == ^user_id and
          a.activity_type == "Create" and
          a.object_id == ^activitypub_id,
      order_by: [desc: a.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp latest_local_create_activity(_, _), do: nil

  defp latest_local_community_create_activity(%Message{activitypub_id: activitypub_id}, actor_uri)
       when is_binary(activitypub_id) and is_binary(actor_uri) do
    from(a in ActivityPub.Activity,
      where:
        a.local == true and
          is_nil(a.internal_user_id) and
          a.actor_uri == ^actor_uri and
          a.activity_type == "Create" and
          a.object_id == ^activitypub_id,
      order_by: [desc: a.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp latest_local_community_create_activity(_, _), do: nil

  defp activity_audience_opts(create_activity, fallback_object) do
    audience_source =
      if is_map(create_activity && create_activity.data), do: create_activity.data, else: %{}

    %{
      to:
        Map.get(audience_source, "to") || get_in(audience_source, ["object", "to"]) ||
          fallback_object["to"],
      cc:
        Map.get(audience_source, "cc") || get_in(audience_source, ["object", "cc"]) ||
          fallback_object["cc"]
    }
  end

  defp former_type_for_message(%Message{post_type: "poll"}), do: "Question"
  defp former_type_for_message(_message), do: "Note"

  defp federate_user_delete(%Message{} = message) do
    with activitypub_id when not is_nil(activitypub_id) <- message.activitypub_id,
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id) do
      create_activity = latest_local_create_activity(message, user.id)

      delete_activity =
        Builder.build_delete_activity(
          user,
          activitypub_id,
          former_type_for_message(message),
          activity_audience_opts(create_activity, build_post_object(message, user))
        )

      inbox_urls = update_delete_inboxes(message, user.id, create_activity)
      maybe_publish(delete_activity, user, inbox_urls)
    end
  end

  defp federate_user_update(%Message{} = message) do
    with true <- not is_nil(message.activitypub_id),
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id) do
      create_activity = latest_local_create_activity(message, user.id)

      updated_object =
        message
        |> build_post_object(user)
        |> preserve_original_object_routing(create_activity)

      update_activity =
        Builder.build_update_activity(
          user,
          updated_object,
          activity_audience_opts(create_activity, updated_object)
        )

      inbox_urls = update_delete_inboxes(message, user.id, create_activity)
      maybe_publish(update_activity, user, inbox_urls)
    end
  end

  defp federate_local_community_delete(%Message{} = message, community) do
    with activitypub_id when not is_nil(activitypub_id) <- message.activitypub_id,
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id),
         {:ok, community_actor} <- ActivityPub.get_or_create_community_actor(community.id) do
      author_uri = ActivityPub.actor_uri(user)
      community_object = build_community_post_object(message, community, author_uri)
      create_activity = latest_local_community_create_activity(message, community_actor.uri)

      delete_activity =
        Builder.build_delete_activity(
          community_actor,
          activitypub_id,
          former_type_for_message(message),
          activity_audience_opts(create_activity, community_object)
        )

      inbox_urls = community_update_delete_inboxes(message, community_actor.id, create_activity)
      maybe_publish(delete_activity, nil, inbox_urls)
    end
  end

  defp federate_local_community_update(%Message{} = message, community) do
    with true <- not is_nil(message.activitypub_id),
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id),
         {:ok, community_actor} <- ActivityPub.get_or_create_community_actor(community.id) do
      create_activity = latest_local_community_create_activity(message, community_actor.uri)

      updated_object =
        build_community_post_object(
          message,
          community,
          ActivityPub.actor_uri(user)
        )
        |> preserve_original_object_routing(create_activity)

      update_activity =
        Builder.build_update_activity(
          community_actor,
          updated_object,
          activity_audience_opts(create_activity, updated_object)
        )

      inbox_urls = community_update_delete_inboxes(message, community_actor.id, create_activity)
      maybe_publish(update_activity, nil, inbox_urls)
    end
  end

  defp local_public_community(%Message{} = message) do
    case message_conversation(message) do
      %Elektrine.Messaging.Conversation{
        type: "community",
        is_public: true,
        is_federated_mirror: false
      } = community ->
        {:ok, community}

      _ ->
        :error
    end
  end

  defp message_conversation(%Message{
         conversation: %Ecto.Association.NotLoaded{},
         conversation_id: id
       }),
       do: Repo.get(Elektrine.Messaging.Conversation, id)

  defp message_conversation(%Message{conversation: nil, conversation_id: id}),
    do: Repo.get(Elektrine.Messaging.Conversation, id)

  defp message_conversation(%Message{conversation: conversation}), do: conversation

  defp community_post_inboxes(message, community_actor_id) do
    (relay_inboxes_for_visibility(message.visibility) ++
       ActivityPub.get_group_follower_inboxes(community_actor_id) ++
       mention_inboxes_for_message(message))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Federates a community post to remote followers.
  Called when a discussion post is created in a public community.
  """
  def federate_community_post(%Message{} = message, community) do
    if community.is_public && message.sender_id do
      # Check if this is a federated mirror - send differently
      if community.is_federated_mirror && community.remote_group_actor_id do
        federate_post_to_remote_group(message, community)
      else
        # Local community - create our own Group actor
        federate_local_community_post(message, community)
      end
    end

    :ok
  end

  defp federate_local_community_post(message, community) do
    with {:ok, community_actor} <- ActivityPub.get_or_create_community_actor(community.id),
         %Accounts.User{activitypub_enabled: true} = user <- Accounts.get_user!(message.sender_id) do
      post_id = ActivityPub.community_post_uri(community.name, message.id)

      page_object =
        build_community_post_object(
          message,
          community,
          ActivityPub.actor_uri(user)
        )

      create_activity = Builder.build_community_create_activity(message, community, page_object)

      maybe_set_community_activitypub_id(message, community, post_id)

      all_inboxes = community_post_inboxes(message, community_actor.id)

      # Community actors don't have a local User, so we publish with `nil` actor user.
      maybe_publish(create_activity, nil, all_inboxes)
    else
      %Accounts.User{activitypub_enabled: false} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to create community actor: #{inspect(reason)}")
    end
  end

  defp maybe_set_community_activitypub_id(
         %Message{activitypub_id: nil} = message,
         community,
         post_id
       ) do
    Elektrine.Messaging.update_message(message, %{
      activitypub_id: post_id,
      activitypub_url: ActivityPub.community_post_web_url(community.name, message.id)
    })
  end

  defp maybe_set_community_activitypub_id(_message, _community, _post_id), do: :ok

  @doc """
  Sends a poll vote for a remote ActivityPub poll (viewed on remote post page).
  Creates and sends a Create{Note} activity with the option name to the poll author.
  """
  def send_poll_vote(user, poll_id, option_name, remote_actor) do
    if user.activitypub_enabled && remote_actor && remote_actor.inbox_url do
      base_url = ActivityPub.instance_url()

      # Build vote Note object
      vote_object = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" =>
          "#{ActivityPub.actor_uri(user, base_url)}/votes/#{:erlang.unique_integer([:positive])}",
        "type" => "Note",
        "name" => option_name,
        "inReplyTo" => poll_id,
        "attributedTo" => ActivityPub.actor_uri(user, base_url),
        "to" => [remote_actor.uri],
        "cc" => []
      }

      # Build Create activity
      create_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{vote_object["id"]}/activity",
        "type" => "Create",
        "actor" => ActivityPub.actor_uri(user, base_url),
        "to" => [remote_actor.uri],
        "cc" => [],
        "object" => vote_object
      }

      # Send to poll author's inbox
      Publisher.publish(create_activity, user, [remote_actor.inbox_url])
      :ok
    else
      :ok
    end
  end

  @doc """
  Sends a poll vote to the remote instance (for local federated polls).
  ActivityPub poll votes are sent as Create{Note} with the option name.
  """
  def federate_poll_vote(poll, option, user, message) do
    if user.activitypub_enabled && message.federated && message.activitypub_id do
      # Get the remote actor who created the poll
      remote_actor =
        if message.remote_actor_id do
          Elektrine.Repo.get(ActivityPub.Actor, message.remote_actor_id)
        end

      if remote_actor && remote_actor.inbox_url do
        base_url = ActivityPub.instance_url()

        # Build vote Note object
        vote_object = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{ActivityPub.actor_uri(user, base_url)}/votes/#{poll.id}/#{option.id}",
          "type" => "Note",
          "name" => option.option_text,
          "inReplyTo" => message.activitypub_id,
          "attributedTo" => ActivityPub.actor_uri(user, base_url),
          "to" => [remote_actor.uri],
          "cc" => []
        }

        # Build Create activity
        create_activity = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{vote_object["id"]}/activity",
          "type" => "Create",
          "actor" => ActivityPub.actor_uri(user, base_url),
          "to" => [remote_actor.uri],
          "cc" => [],
          "object" => vote_object
        }

        # Send to poll author's inbox
        Publisher.publish(create_activity, user, [remote_actor.inbox_url])
        :ok
      else
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Sends a Flag (report) activity to a remote instance.
  Used when reporting remote users or their content.

  ## Parameters
  - `reporter_id` - The local user making the report
  - `target_actor_uri` - The AP URI of the user being reported
  - `object_uris` - List of content URIs being reported (optional)
  - `reason` - The report reason/description
  """
  def federate_report(reporter_id, target_actor_uri, object_uris \\ [], reason \\ nil) do
    user = Accounts.get_user!(reporter_id)

    if user.activitypub_enabled && target_actor_uri do
      # Build Flag activity
      flag_activity = Builder.build_flag_activity(user, target_actor_uri, object_uris, reason)

      # Determine the inbox to send to (the instance of the reported user)
      inbox_url = get_instance_inbox_from_uri(target_actor_uri)

      if inbox_url do
        Logger.info(
          "Federating report from #{user.username} against #{target_actor_uri} to #{inbox_url}"
        )

        Publisher.publish(flag_activity, user, [inbox_url])
      else
        Logger.warning("Could not determine inbox for report target: #{target_actor_uri}")
      end
    end

    :ok
  end

  defp target_inboxes_for_message(%Message{} = message) do
    cond do
      message.federated && message.remote_actor_id ->
        actor_inbox_for_remote_actor(message.remote_actor_id)

      message.sender_id ->
        follower_inboxes_for_author(message.sender_id)

      true ->
        []
    end
  end

  defp maybe_remote_author_inbox(%Message{federated: true, remote_actor_id: remote_actor_id})
       when not is_nil(remote_actor_id) do
    actor_inbox_for_remote_actor(remote_actor_id)
  end

  defp maybe_remote_author_inbox(_), do: []

  defp actor_inbox_for_remote_actor(remote_actor_id) do
    case Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id) do
      %ActivityPub.Actor{inbox_url: inbox_url} when is_binary(inbox_url) -> [inbox_url]
      _ -> []
    end
  end

  defp follower_inboxes_for_author(sender_id) do
    author = Accounts.get_user!(sender_id)
    if author.activitypub_enabled, do: Publisher.get_follower_inboxes(author.id), else: []
  end

  defp latest_local_activity_data(user_id, activity_type, object_id, opts \\ []) do
    case ActivityPub.get_latest_local_activity(user_id, activity_type, object_id, opts) do
      %{data: data} when is_map(data) -> data
      _ -> nil
    end
  end

  defp maybe_add_remote_author_audience(
         %Message{federated: true, remote_actor_id: remote_actor_id},
         activity
       )
       when is_map(activity) and not is_nil(remote_actor_id) do
    case Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id) do
      %ActivityPub.Actor{uri: actor_uri} when is_binary(actor_uri) and actor_uri != "" ->
        Map.put_new(activity, "to", [actor_uri])

      _ ->
        activity
    end
  end

  defp maybe_add_remote_author_audience(_, activity), do: activity

  # Get the instance inbox from an actor URI
  defp get_instance_inbox_from_uri(actor_uri) when is_binary(actor_uri) do
    # First try to get the actor from our database
    case ActivityPub.get_actor_by_uri(actor_uri) do
      %{metadata: metadata, inbox_url: inbox} ->
        shared_inbox = get_in(metadata || %{}, ["endpoints", "sharedInbox"])

        case preferred_actor_inbox(shared_inbox, inbox) do
          nil -> fallback_instance_inbox(actor_uri)
          inbox_url -> inbox_url
        end

      _ ->
        fallback_instance_inbox(actor_uri)
    end
  end

  defp get_instance_inbox_from_uri(_), do: nil

  defp preferred_actor_inbox(shared_inbox, inbox_url) do
    case shared_inbox do
      value when is_binary(value) and value != "" -> value
      _ -> if(is_binary(inbox_url) and inbox_url != "", do: inbox_url, else: nil)
    end
  end

  defp fallback_instance_inbox(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        "#{uri_origin(scheme, host, port)}/inbox"

      _ ->
        nil
    end
  end

  defp uri_origin(scheme, host, port) when port in [80, 443, nil],
    do: "#{scheme}://#{host}"

  defp uri_origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"

  defp preserve_original_object_routing(updated_object, nil), do: updated_object

  defp preserve_original_object_routing(updated_object, %ActivityPub.Activity{data: data})
       when is_map(updated_object) and is_map(data) do
    case Map.get(data, "object") do
      original_object when is_map(original_object) ->
        Enum.reduce(["to", "cc", "audience", "context"], updated_object, fn field, acc ->
          case Map.get(original_object, field) do
            nil -> acc
            value -> Map.put(acc, field, value)
          end
        end)

      _ ->
        updated_object
    end
  end

  defp preserve_original_object_routing(updated_object, _), do: updated_object

  # Federates a post to a remote Group actor.
  defp federate_post_to_remote_group(message, mirror_community) do
    user = Accounts.get_user!(message.sender_id)
    remote_group = Elektrine.Repo.get(ActivityPub.Actor, mirror_community.remote_group_actor_id)

    if remote_group && remote_group.inbox_url do
      # Build Note object for the post
      note = Builder.build_note(message, user)

      # Add audience field to indicate this is for the Group
      note =
        Map.merge(note, %{
          "audience" => remote_group.uri,
          "context" => remote_group.uri,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [remote_group.uri]
        })

      # Build Create activity
      create_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{note["id"]}/activity",
        "type" => "Create",
        "actor" => ActivityPub.actor_uri(user),
        "published" => Builder.format_datetime(message.inserted_at),
        "to" => note["to"],
        "cc" => note["cc"],
        "object" => note
      }

      # Set ActivityPub ID on the message
      if !message.activitypub_id do
        Elektrine.Messaging.update_message(message, %{
          activitypub_id: note["id"],
          activitypub_url: note["id"]
        })
      end

      # Send to the Group's inbox
      Publisher.publish(create_activity, user, [remote_group.inbox_url])
    else
      Logger.warning("Remote group actor not found or has no inbox")
    end
  end
end
