defmodule Elektrine.ActivityPub.Outbox do
  @moduledoc """
  Handles outgoing ActivityPub activities.
  Publishes local user actions to remote followers.
  """

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Builder, Fetcher, Mentions, Publisher}
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.Poll

  @doc """
  Federates a newly created message/post to remote followers.
  Called automatically when a user creates a public or followers-only post.
  """
  def federate_post(%Message{} = message) do
    with true <- federatable_post?(message),
         %{} = user <- activitypub_user(message.sender_id) do
      poll = maybe_poll_for_message(message)
      create_activity = build_post_create_activity(message, user, poll)
      maybe_set_message_activitypub_id(message, create_activity["object"]["id"])

      base_inboxes = base_post_inboxes(message, user.id)
      mention_inboxes = mention_inboxes_for_message(message)
      relay_inboxes = relay_inboxes_for_visibility(message.visibility)
      community_uri = get_community_uri_from_chain(message)
      community_inboxes = community_inboxes_for_uri(community_uri)

      inbox_urls =
        (base_inboxes ++ mention_inboxes ++ relay_inboxes ++ community_inboxes) |> Enum.uniq()

      Logger.debug(
        "Federating post #{message.id}: " <>
          "base=#{length(base_inboxes)}, mentions=#{length(mention_inboxes)}, " <>
          "relays=#{length(relay_inboxes)}, community=#{length(community_inboxes)}, " <>
          "total=#{length(inbox_urls)}, community_uri=#{inspect(community_uri)}"
      )

      publish_post_activity(message, create_activity, user, inbox_urls)
    end

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
    Repo.get_by(Poll, message_id: message_id)
    |> Repo.preload(:options)
  end

  defp maybe_poll_for_message(_), do: nil

  defp build_post_create_activity(message, user, nil),
    do: Builder.build_create_activity(message, user)

  defp build_post_create_activity(message, user, poll) do
    question = Builder.build_question(message, user, poll)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{question["id"]}/activity",
      "type" => "Create",
      "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
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

        # Also get the instance's shared inbox from the activitypub_id domain
        # This is important for Lemmy where the shared inbox receives all community activity
        instance_inbox = get_instance_shared_inbox(parent.activitypub_id)

        inboxes = [author_inbox, instance_inbox | base_inboxes]

        Enum.uniq(Enum.reject(inboxes, &is_nil/1))
      else
        Logger.warning("Remote actor not found for federated parent")
        base_inboxes
      end
    else
      base_inboxes
    end
  end

  # Get the shared inbox for an instance based on an ActivityPub ID
  defp get_instance_shared_inbox(activitypub_id) when is_binary(activitypub_id) do
    case URI.parse(activitypub_id) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        "#{scheme}://#{host}/inbox"

      _ ->
        nil
    end
  end

  defp get_instance_shared_inbox(_), do: nil

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
      # Build original Like activity
      like_activity = Builder.build_like_activity(user, message.activitypub_id)

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
      like_activity = Builder.build_like_activity(user, message.activitypub_id)

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
      dislike_activity = Builder.build_dislike_activity(user, message.activitypub_id)

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
      # Build original Dislike activity
      dislike_activity = Builder.build_dislike_activity(user, message.activitypub_id)

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
      # Build original Announce activity
      announce_activity = Builder.build_announce_activity(user, message.activitypub_id)

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
        "actor" => "#{base_url}/users/#{user.username}",
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
      # Build original EmojiReact activity
      emoji_react_activity =
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
    with activitypub_id when not is_nil(activitypub_id) <- message.activitypub_id,
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id) do
      delete_activity = Builder.build_delete_activity(user, activitypub_id)
      inbox_urls = Publisher.get_follower_inboxes(user.id)
      maybe_publish(delete_activity, user, inbox_urls)
    end

    :ok
  end

  @doc """
  Sends an Update activity when a message is edited.
  """
  def federate_update(%Message{} = message) do
    with true <- not is_nil(message.activitypub_id),
         sender_id when not is_nil(sender_id) <- message.sender_id,
         %{} = user <- activitypub_user(sender_id) do
      updated_note = Builder.build_note(message, user)
      update_activity = Builder.build_update_activity(user, updated_note)
      inbox_urls = Publisher.get_follower_inboxes(user.id)
      maybe_publish(update_activity, user, inbox_urls)
    end

    :ok
  end

  @doc """
  Sends an Update activity when user updates their profile.
  """
  def federate_profile_update(user_id) do
    user = Accounts.get_user!(user_id)

    if user.activitypub_enabled do
      # Need to load profile
      user = Elektrine.Repo.preload(user, :profile)

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
  end

  defp federate_local_community_post(message, community) do
    with {:ok, community_actor} <- ActivityPub.get_or_create_community_actor(community.id),
         user <- Accounts.get_user!(message.sender_id) do
      post_id = community_post_id(community, message.id)

      page_object =
        build_community_page_object(message, community, community_actor, user, post_id)

      create_activity =
        build_community_create_activity(message, community_actor, page_object, post_id)

      maybe_set_community_activitypub_id(message, community, post_id)

      all_inboxes =
        (ActivityPub.get_relay_inboxes() ++
           ActivityPub.get_group_follower_inboxes(community_actor.id))
        |> Enum.uniq()

      # Community actors don't have a local User, so we publish with `nil` actor user.
      maybe_publish(create_activity, nil, all_inboxes)
    else
      {:error, reason} ->
        Logger.error("Failed to create community actor: #{inspect(reason)}")
    end
  end

  defp community_post_id(community, message_id) do
    base_url = ActivityPub.instance_url()
    community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
    "#{base_url}/c/#{community_slug}/posts/#{message_id}"
  end

  defp build_community_page_object(message, community, community_actor, user, post_id) do
    base_url = ActivityPub.instance_url()

    %{
      "id" => post_id,
      "type" => community_object_type(message),
      "attributedTo" => "#{base_url}/users/#{user.username}",
      "content" => message.content || "",
      "mediaType" => "text/html",
      "published" => Builder.format_datetime(message.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [community_actor.uri],
      "audience" => community_actor.uri,
      "url" => "#{base_url}/communities/#{community.name}/post/#{message.id}",
      "inReplyTo" => nil,
      "sensitive" => message.sensitive || false,
      "context" => community_actor.uri,
      "commentsEnabled" => is_nil(message.locked_at),
      "stickied" => message.is_pinned || false
    }
    |> maybe_put("name", message.title)
    |> maybe_put("summary", message.content_warning)
    |> maybe_put("updated", format_updated_at(message.edited_at))
  end

  defp community_object_type(%Message{reply_to_id: nil}), do: "Page"
  defp community_object_type(_), do: "Note"

  defp format_updated_at(nil), do: nil
  defp format_updated_at(edited_at), do: Builder.format_datetime(edited_at)

  defp build_community_create_activity(message, community_actor, page_object, post_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{post_id}/activity",
      "type" => "Create",
      "actor" => community_actor.uri,
      "published" => Builder.format_datetime(message.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [community_actor.followers_url],
      "object" => page_object
    }
  end

  defp maybe_set_community_activitypub_id(
         %Message{activitypub_id: nil} = message,
         community,
         post_id
       ) do
    base_url = ActivityPub.instance_url()

    Elektrine.Messaging.update_message(message, %{
      activitypub_id: post_id,
      activitypub_url: "#{base_url}/communities/#{community.name}/post/#{message.id}"
    })
  end

  defp maybe_set_community_activitypub_id(_message, _community, _post_id), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
        "id" => "#{base_url}/users/#{user.username}/votes/#{:erlang.unique_integer([:positive])}",
        "type" => "Note",
        "name" => option_name,
        "inReplyTo" => poll_id,
        "attributedTo" => "#{base_url}/users/#{user.username}",
        "to" => [remote_actor.uri],
        "cc" => []
      }

      # Build Create activity
      create_activity = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{vote_object["id"]}/activity",
        "type" => "Create",
        "actor" => "#{base_url}/users/#{user.username}",
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
          "id" => "#{base_url}/users/#{user.username}/votes/#{poll.id}/#{option.id}",
          "type" => "Note",
          "name" => option.option_text,
          "inReplyTo" => message.activitypub_id,
          "attributedTo" => "#{base_url}/users/#{user.username}",
          "to" => [remote_actor.uri],
          "cc" => []
        }

        # Build Create activity
        create_activity = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "#{vote_object["id"]}/activity",
          "type" => "Create",
          "actor" => "#{base_url}/users/#{user.username}",
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

  # Get the instance inbox from an actor URI
  defp get_instance_inbox_from_uri(actor_uri) when is_binary(actor_uri) do
    # First try to get the actor from our database
    case ActivityPub.get_actor_by_uri(actor_uri) do
      %{inbox_url: inbox} when is_binary(inbox) ->
        inbox

      _ ->
        # Fall back to constructing the shared inbox from the domain
        case URI.parse(actor_uri) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            "#{scheme}://#{host}/inbox"

          _ ->
            nil
        end
    end
  end

  defp get_instance_inbox_from_uri(_), do: nil

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
        "actor" => "#{ActivityPub.instance_url()}/users/#{user.username}",
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
