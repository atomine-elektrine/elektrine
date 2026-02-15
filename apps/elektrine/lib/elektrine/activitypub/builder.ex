defmodule Elektrine.ActivityPub.Builder do
  @moduledoc """
  Builds ActivityPub JSON-LD documents for actors, activities, and objects.
  """

  alias Elektrine.ActivityPub
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.Message

  @doc """
  Builds an Actor document for a user.
  """
  def build_actor(%User{} = user) do
    base_url = ActivityPub.instance_url()
    actor_url = "#{base_url}/users/#{user.username}"

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor_url,
      "type" => "Person",
      "preferredUsername" => user.username,
      "name" => user.display_name || user.username,
      "summary" => build_user_summary(user),
      "url" => "#{base_url}/#{user.handle}",
      "inbox" => "#{actor_url}/inbox",
      "outbox" => "#{actor_url}/outbox",
      "followers" => "#{actor_url}/followers",
      "following" => "#{actor_url}/following",
      "published" => format_datetime(user.inserted_at),
      "manuallyApprovesFollowers" => user.activitypub_manually_approve_followers || false,
      "discoverable" => user.profile_visibility == "public",
      "icon" => build_icon(user),
      "image" => build_header_image(user),
      "publicKey" => %{
        "id" => "#{actor_url}#main-key",
        "owner" => actor_url,
        "publicKeyPem" => String.trim(user.activitypub_public_key || "")
      },
      "endpoints" => %{
        "sharedInbox" => "#{base_url}/inbox"
      }
    }
  end

  defp build_user_summary(user) do
    # Get user profile bio if available
    case user.profile do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> nil
      profile -> Map.get(profile, :description)
    end
  end

  defp build_icon(user) do
    if user.avatar do
      # Convert avatar to full URL for federation
      avatar_url = Elektrine.Uploads.avatar_url(user.avatar)

      %{
        "type" => "Image",
        "mediaType" => guess_media_type(avatar_url),
        "url" => avatar_url
      }
    else
      nil
    end
  end

  defp build_header_image(user) do
    # Check if user has a banner image
    case user.profile do
      %Ecto.Association.NotLoaded{} ->
        nil

      nil ->
        nil

      profile ->
        banner = Map.get(profile, :banner_url)

        if banner do
          # Ensure banner URL is absolute
          banner_url =
            if String.starts_with?(banner, "http") do
              banner
            else
              "#{ActivityPub.instance_url()}#{banner}"
            end

          %{
            "type" => "Image",
            "mediaType" => guess_media_type(banner_url),
            "url" => banner_url
          }
        else
          nil
        end
    end
  end

  @doc """
  Builds a Group actor document for a community/discussion (Lemmy-compatible).
  """
  def build_group(%Elektrine.Messaging.Conversation{} = community) do
    base_url = ActivityPub.instance_url()
    # Use community name as identifier (URL-safe)
    community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
    actor_url = "#{base_url}/c/#{community_slug}"
    public_key = get_community_public_key(community)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        %{
          "lemmy" => "https://join-lemmy.org/ns#",
          "moderators" => %{
            "@type" => "@id",
            "@id" => "lemmy:moderators"
          },
          "postingRestrictedToMods" => "lemmy:postingRestrictedToMods"
        }
      ],
      "id" => actor_url,
      "type" => "Group",
      "preferredUsername" => community_slug,
      "name" => community.name,
      "summary" => community.description || "A community on #{ActivityPub.instance_domain()}",
      "url" => "#{base_url}/communities/#{community.name}",
      "inbox" => "#{actor_url}/inbox",
      "outbox" => "#{actor_url}/outbox",
      "followers" => "#{actor_url}/followers",
      "moderators" => "#{actor_url}/moderators",
      "published" => format_datetime(community.inserted_at),
      "manuallyApprovesFollowers" => !community.is_public,
      "discoverable" => community.is_public,
      "postingRestrictedToMods" => false,
      "icon" => build_community_icon(community),
      "publicKey" => %{
        "id" => "#{actor_url}#main-key",
        "owner" => actor_url,
        "publicKeyPem" => String.trim(public_key)
      },
      "endpoints" => %{
        "sharedInbox" => "#{base_url}/inbox"
      },
      "attributedTo" => build_community_moderators(community)
    }
  end

  defp get_community_public_key(community) do
    case ActivityPub.get_or_create_community_actor(community.id) do
      {:ok, actor} ->
        actor =
          case Elektrine.ActivityPub.KeyManager.ensure_user_has_keys(actor) do
            {:ok, actor_with_keys} -> actor_with_keys
            _ -> actor
          end

        actor.public_key || ""

      {:error, _reason} ->
        ""
    end
  end

  defp build_community_icon(community) do
    if community.avatar_url do
      %{
        "type" => "Image",
        "mediaType" => guess_media_type(community.avatar_url),
        "url" => community.avatar_url
      }
    else
      nil
    end
  end

  defp build_community_moderators(community) do
    # Return list of moderator actor URIs
    # Use the creator as the moderator list until role mapping is implemented.
    base_url = ActivityPub.instance_url()

    if community.creator_id do
      try do
        creator = Elektrine.Accounts.get_user!(community.creator_id)
        ["#{base_url}/users/#{creator.username}"]
      rescue
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Builds a Note object from a message.
  """
  def build_note(%Message{} = message, %User{} = user) do
    base_url = ActivityPub.instance_url()

    object_id =
      message.activitypub_id || "#{base_url}/users/#{user.username}/statuses/#{message.id}"

    # Check if posting to a community - walk up reply chain if needed
    community_uri = get_community_uri_from_chain(message)

    note = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => object_id,
      "type" => "Note",
      "attributedTo" => "#{base_url}/users/#{user.username}",
      "content" => format_content(message),
      "published" => format_datetime(message.inserted_at),
      "to" => build_to_addresses(message, community_uri),
      "cc" => build_cc_addresses(message, user),
      "sensitive" => message.sensitive || false,
      "attachment" => build_attachments(message),
      "tag" => build_tags(message),
      "url" => object_id,
      "inReplyTo" => build_in_reply_to(message)
    }

    # Add audience for community posts
    note =
      if community_uri do
        Map.put(note, "audience", community_uri)
      else
        note
      end

    note
    |> maybe_add_content_warning(message)
    |> maybe_add_title_as_name(message)
    |> maybe_add_quote_url(message)
  end

  @doc """
  Formats a datetime for ActivityPub (ISO8601).
  """
  def format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def format_datetime(%NaiveDateTime{} = ndt) do
    # Convert NaiveDateTime to DateTime (assume UTC)
    DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_iso8601()
  end

  def format_datetime(nil), do: nil

  defp format_content(message) do
    # Convert message content to HTML
    # Handle nil or empty content (e.g., boost posts)
    content = message.content || ""

    if String.trim(content) == "" do
      ""
    else
      content
      |> String.replace("\n", "<br>")
      |> HtmlSanitizeEx.basic_html()
    end
  end

  defp build_to_addresses(message, community_uri \\ nil) do
    base =
      case message.visibility do
        "public" ->
          ["https://www.w3.org/ns/activitystreams#Public"]

        "followers" ->
          # Send to followers collection
          []

        _ ->
          # Direct/conversation - send to specific recipients
          []
      end

    # Add community URI if posting to a community
    if community_uri do
      [community_uri | base]
    else
      base
    end
  end

  defp build_cc_addresses(message, user) do
    base_url = ActivityPub.instance_url()

    base_cc =
      case message.visibility do
        "public" ->
          # CC to followers when posting publicly
          ["#{base_url}/users/#{user.username}/followers"]

        _ ->
          []
      end

    # Add mentioned users (handle nil content)
    mention_uris =
      if message.content do
        Elektrine.ActivityPub.Mentions.get_mention_uris(message.content)
      else
        []
      end

    base_cc ++ mention_uris
  end

  defp build_attachments(message) do
    if message.media_urls && message.media_urls != [] do
      # Get alt texts from metadata if available
      alt_texts =
        if message.media_metadata && message.media_metadata["alt_texts"] do
          message.media_metadata["alt_texts"]
        else
          %{}
        end

      Enum.with_index(message.media_urls)
      |> Enum.map(fn {key, idx} ->
        # Convert S3 key to full public URL
        full_url = Elektrine.Uploads.media_url(key)
        media_type = guess_media_type(full_url)

        # Use appropriate ActivityPub type based on media type
        attachment_type =
          cond do
            String.starts_with?(media_type, "image/") -> "Image"
            String.starts_with?(media_type, "video/") -> "Video"
            String.starts_with?(media_type, "audio/") -> "Audio"
            true -> "Document"
          end

        # Build attachment object (Pixelfed-compatible)
        attachment = %{
          "type" => attachment_type,
          "mediaType" => media_type,
          "url" => full_url
        }

        # Add alt text (name field) if available
        alt_text = Map.get(alt_texts, to_string(idx))

        if alt_text && String.trim(alt_text) != "" do
          Map.put(attachment, "name", alt_text)
        else
          attachment
        end
      end)
    else
      []
    end
  end

  defp guess_media_type(url) do
    cond do
      String.ends_with?(url, [".jpg", ".jpeg"]) -> "image/jpeg"
      String.ends_with?(url, ".png") -> "image/png"
      String.ends_with?(url, ".gif") -> "image/gif"
      String.ends_with?(url, ".webp") -> "image/webp"
      String.ends_with?(url, ".mp4") -> "video/mp4"
      String.ends_with?(url, ".webm") -> "video/webm"
      String.ends_with?(url, ".ogv") -> "video/ogg"
      String.ends_with?(url, ".mov") -> "video/quicktime"
      String.ends_with?(url, ".mp3") -> "audio/mpeg"
      String.ends_with?(url, ".ogg") -> "audio/ogg"
      String.ends_with?(url, ".wav") -> "audio/wav"
      String.ends_with?(url, ".m4a") -> "audio/mp4"
      String.ends_with?(url, ".aac") -> "audio/aac"
      String.ends_with?(url, ".flac") -> "audio/flac"
      true -> "application/octet-stream"
    end
  end

  defp build_tags(message) do
    tags = []

    # Add hashtags
    hashtag_tags =
      if message.extracted_hashtags && message.extracted_hashtags != [] do
        Enum.map(message.extracted_hashtags, fn tag ->
          %{
            "type" => "Hashtag",
            "name" => "##{tag}",
            "href" => "#{Elektrine.ActivityPub.instance_url()}/hashtag/#{tag}"
          }
        end)
      else
        []
      end

    # Add mentions from content
    mention_tags =
      if message.content do
        Elektrine.ActivityPub.Mentions.resolve_mentions(message.content)
        |> Enum.map(fn mention ->
          %{
            "type" => "Mention",
            "href" => mention.uri,
            "name" => "@#{mention.handle}"
          }
        end)
      else
        []
      end

    tags ++ hashtag_tags ++ mention_tags
  end

  defp build_in_reply_to(message) do
    if message.reply_to_id do
      # Get the parent message
      parent = Elektrine.Messaging.get_message(message.reply_to_id)

      if parent && parent.activitypub_id do
        parent.activitypub_id
      else
        nil
      end
    else
      nil
    end
  end

  # Add content warning as summary field (for sensitive content / spoiler text)
  defp maybe_add_content_warning(note, message) do
    if message.content_warning && String.trim(message.content_warning) != "" do
      Map.put(note, "summary", message.content_warning)
    else
      note
    end
  end

  # Add title as name field (for titled posts like Article-style)
  defp maybe_add_title_as_name(note, message) do
    if message.title && String.trim(message.title) != "" do
      Map.put(note, "name", message.title)
    else
      note
    end
  end

  # Add quoteUrl for quote posts (Mastodon-style quoting)
  defp maybe_add_quote_url(note, message) do
    if message.quoted_message_id do
      # Load the quoted message if not already loaded
      quoted_message =
        case message.quoted_message do
          %Elektrine.Messaging.Message{} = qm -> qm
          _ -> Elektrine.Repo.get(Elektrine.Messaging.Message, message.quoted_message_id)
        end

      if quoted_message && quoted_message.activitypub_id do
        # Use quoteUrl field (Mastodon 4.3+ standard)
        note
        |> Map.put("quoteUrl", quoted_message.activitypub_id)
        # Also add _misskey_quote for Misskey/Calckey compatibility
        |> Map.put("_misskey_quote", quoted_message.activitypub_id)
      else
        note
      end
    else
      note
    end
  end

  @doc """
  Builds a Create activity for a message.
  """
  def build_create_activity(%Message{} = message, %User{} = user) do
    base_url = ActivityPub.instance_url()
    note = build_note(message, user)
    activity_id = "#{note["id"]}/activity"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Create",
      "actor" => "#{base_url}/users/#{user.username}",
      "published" => format_datetime(message.inserted_at),
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }
  end

  @doc """
  Builds a Question object for a poll.
  """
  def build_question(%Message{} = message, %User{} = user, poll) do
    base_url = ActivityPub.instance_url()

    object_id =
      message.activitypub_id || "#{base_url}/users/#{user.username}/statuses/#{message.id}"

    # Build poll options
    options =
      Enum.map(poll.options, fn option ->
        %{
          "type" => "Note",
          "name" => option.option_text,
          "replies" => %{
            "type" => "Collection",
            "totalItems" => option.vote_count || 0
          }
        }
      end)

    # Determine end time
    end_time =
      if poll.closes_at do
        format_datetime(poll.closes_at)
      else
        # Default: 24 hours from now
        DateTime.add(DateTime.utc_now(), 24 * 3600, :second) |> DateTime.to_iso8601()
      end

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => object_id,
      "type" => "Question",
      "attributedTo" => "#{base_url}/users/#{user.username}",
      "content" => format_content(message),
      "published" => format_datetime(message.inserted_at),
      "endTime" => end_time,
      "closed" => format_datetime(poll.closes_at),
      "votersCount" => poll.total_votes || 0,
      if(poll.allow_multiple, do: "anyOf", else: "oneOf") => options,
      "to" => build_to_addresses(message),
      "cc" => build_cc_addresses(message, user)
    }
  end

  @doc """
  Builds a Follow activity.
  """
  def build_follow_activity(%User{} = follower, target_uri) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Follow",
      "actor" => "#{base_url}/users/#{follower.username}",
      "object" => target_uri,
      "to" => [target_uri],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Builds an Accept activity (for accepting follows).
  """
  def build_accept_activity(%User{} = user, follow_activity) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Accept",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => follow_activity
    }
  end

  @doc """
  Builds a Reject activity (for rejecting follows).
  """
  def build_reject_activity(%User{} = user, follow_activity) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Reject",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => follow_activity
    }
  end

  @doc """
  Builds an Announce activity (boost/share).
  """
  def build_announce_activity(%User{} = user, object_uri) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Announce",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object_uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["#{base_url}/users/#{user.username}/followers"]
    }
  end

  @doc """
  Builds a Like activity.
  """
  def build_like_activity(%User{} = user, object_uri) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Like",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object_uri
    }
  end

  @doc """
  Builds a Dislike activity (downvote).
  """
  def build_dislike_activity(%User{} = user, object_uri) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Dislike",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object_uri
    }
  end

  @doc """
  Builds an EmojiReact activity (for custom emoji reactions).
  """
  def build_emoji_react_activity(%User{} = user, object_uri, emoji) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "EmojiReact",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object_uri,
      "content" => emoji
    }
  end

  @doc """
  Builds a Block activity.
  """
  def build_block_activity(%User{} = user, target_uri) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Block",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => target_uri
    }
  end

  @doc """
  Builds an Undo activity (for undoing follows, likes, etc.).
  """
  def build_undo_activity(%User{} = user, original_activity) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Undo",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => original_activity
    }
  end

  @doc """
  Builds a Delete activity with a Tombstone object.
  """
  def build_delete_activity(%User{} = user, object_uri, former_type \\ "Note") do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    tombstone = %{
      "type" => "Tombstone",
      "id" => object_uri,
      "formerType" => former_type,
      "deleted" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Delete",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => tombstone,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  @doc """
  Builds an Update activity (for profile or post updates).
  """
  def build_update_activity(%User{} = user, object) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Update",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }
  end

  @doc """
  Builds a Flag (report) activity for reporting users or content to remote instances.

  ## Parameters
  - `user` - The user making the report
  - `target_actor_uri` - The AP URI of the user being reported
  - `object_uris` - List of content URIs being reported (posts, etc.)
  - `content` - The report reason/description

  ## Example
      build_flag_activity(user, "https://remote.server/users/baduser", 
        ["https://remote.server/posts/123"], "Spam content")
  """
  def build_flag_activity(%User{} = user, target_actor_uri, object_uris \\ [], content \\ nil) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    # Object is an array containing the reported actor and optionally reported content
    objects =
      [target_actor_uri | List.wrap(object_uris)]
      |> Enum.filter(& &1)
      |> Enum.uniq()

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Flag",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => objects
    }

    # Add content/reason if provided
    if content && content != "" do
      Map.put(activity, "content", content)
    else
      activity
    end
  end

  # Walk up the reply chain to find community_actor_uri (for Lemmy posts)
  # This ensures replies to replies in a Lemmy thread have the correct audience
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
        # Check parent message if this is a reply
        if message.reply_to_id do
          parent = Elektrine.Messaging.get_message(message.reply_to_id)

          if parent do
            get_community_uri_from_chain(parent, depth + 1)
          else
            nil
          end
        else
          nil
        end
    end
  end
end
