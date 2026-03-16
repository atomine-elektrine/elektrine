defmodule Elektrine.ActivityPub.Builder do
  @moduledoc """
  Builds ActivityPub JSON-LD documents for actors, activities, and objects.
  """

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{Conversation, Message}

  @doc """
  Builds an Actor document for a user.
  """
  def build_actor(%User{} = user), do: build_actor(user, %{})

  def build_actor(%User{} = user, opts) when is_map(opts) do
    base_url = Map.get(opts, :base_url, ActivityPub.instance_url())
    moved_to = Map.get(opts, :moved_to)
    also_known_as = Map.get(opts, :also_known_as, [])
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
      "icon" => build_icon(user, base_url),
      "image" => build_header_image(user, base_url),
      "publicKey" => %{
        "id" => "#{actor_url}#main-key",
        "owner" => actor_url,
        "publicKeyPem" => String.trim(user.activitypub_public_key || "")
      },
      "endpoints" => %{
        "sharedInbox" => "#{base_url}/inbox"
      }
    }
    |> maybe_put("movedTo", moved_to)
    |> maybe_put_list("alsoKnownAs", also_known_as)
  end

  defp build_user_summary(user) do
    # Get user profile bio if available
    case user.profile do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> nil
      profile -> Map.get(profile, :description)
    end
  end

  defp build_icon(user, base_url) do
    if user.avatar do
      # Convert avatar to full URL for federation
      avatar_url = user.avatar |> Elektrine.Uploads.avatar_url() |> absolutize_url(base_url)

      %{
        "type" => "Image",
        "mediaType" => guess_media_type(avatar_url),
        "url" => avatar_url
      }
    else
      nil
    end
  end

  defp build_header_image(user, base_url) do
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
              "#{base_url}#{banner}"
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

  defp absolutize_url(nil, _base_url), do: nil

  defp absolutize_url(url, base_url) when is_binary(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      url
    else
      "#{String.trim_trailing(base_url, "/")}#{url}"
    end
  end

  @doc """
  Builds a Group actor document for a community/discussion (Lemmy-compatible).
  """
  def build_group(%Conversation{} = community) do
    base_url = ActivityPub.instance_url()
    community_slug = ActivityPub.community_slug(community.name)
    actor_url = ActivityPub.community_actor_uri(community.name, base_url)
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
      "url" => ActivityPub.community_web_url(community.name, base_url),
      "inbox" => ActivityPub.community_inbox_uri(community.name, base_url),
      "outbox" => ActivityPub.community_outbox_uri(community.name, base_url),
      "followers" => ActivityPub.community_followers_uri(community.name, base_url),
      "moderators" => ActivityPub.community_moderators_uri(community.name, base_url),
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
      "attributedTo" => community_moderator_actor_uris(community, base_url)
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

  def community_moderator_actor_uris(
        %Conversation{} = community,
        base_url \\ ActivityPub.instance_url()
      ) do
    community
    |> moderator_users()
    |> Enum.map(&"#{base_url}/users/#{&1.username}")
  end

  defp moderator_users(%Conversation{} = community) do
    community.id
    |> Messaging.get_community_moderators()
    |> Enum.map(& &1.user)
    |> Enum.filter(&(&1 && &1.activitypub_enabled))
    |> case do
      [] -> creator_user(community)
      users -> users
    end
  end

  defp creator_user(%Conversation{creator_id: nil}), do: []

  defp creator_user(%Conversation{creator_id: creator_id}) do
    case Elektrine.Repo.get(User, creator_id) do
      %User{activitypub_enabled: true} = user -> [user]
      _ -> []
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
      "to" => build_to_addresses(message, user, community_uri),
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

  @doc """
  Builds a community post object for local Group actors.
  """
  def build_community_note(%Message{} = post, %Conversation{} = community, opts \\ []) do
    base_url = get_builder_opt(opts, :base_url, ActivityPub.instance_url())
    community_actor_url = ActivityPub.community_actor_uri(community.name, base_url)
    post_id = ActivityPub.community_post_uri(community.name, post.id, base_url)

    author_uri =
      case get_builder_opt(opts, :author_uri) do
        value when is_binary(value) and value != "" ->
          value

        _ ->
          case post.sender do
            %{username: username} -> "#{base_url}/users/#{username}"
            _ -> community_actor_url
          end
      end

    object_type = if post.reply_to_id, do: "Note", else: "Page"
    cc = community_cc_addresses(post, community_actor_url)

    %{
      "id" => post_id,
      "type" => object_type,
      "attributedTo" => author_uri,
      "content" => format_html_content(post.content),
      "mediaType" => "text/html",
      "published" => format_datetime(post.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => cc,
      "attachment" => build_attachments(post),
      "tag" => build_tags(post),
      "audience" => community_actor_url,
      "url" => ActivityPub.community_post_web_url(community.name, post.id, base_url),
      "inReplyTo" => build_community_in_reply_to(post, community, base_url),
      "sensitive" => post.sensitive || false,
      "context" => community_actor_url,
      "commentsEnabled" => is_nil(post.locked_at),
      "stickied" => post.is_pinned || false,
      "distinguished" => false
    }
    |> maybe_put("updated", format_datetime(post.edited_at))
    |> maybe_put("summary", post.content_warning)
    |> maybe_put("name", if(object_type == "Page", do: post.title, else: nil))
    |> maybe_add_quote_url(post)
  end

  @doc """
  Builds a local community object, choosing Question for polls.
  """
  def build_community_object(%Message{} = post, %Conversation{} = community, opts \\ []) do
    case get_builder_opt(opts, :poll) do
      %{options: _} = poll -> build_community_question(post, community, poll, opts)
      _ -> build_community_note(post, community, opts)
    end
  end

  defp format_content(message) do
    format_html_content(message.content)
  end

  defp format_html_content(content) when is_binary(content) do
    if String.trim(content) == "" do
      ""
    else
      content
      |> String.replace("\n", "<br>")
      |> HtmlSanitizeEx.basic_html()
    end
  end

  defp format_html_content(_), do: ""

  defp build_to_addresses(message, user, community_uri) do
    base_url = ActivityPub.instance_url()

    base =
      case message.visibility do
        "public" ->
          ["https://www.w3.org/ns/activitystreams#Public"]

        "followers" ->
          ["#{base_url}/users/#{user.username}/followers"]

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
    mention_uris = mention_uris_for_message(message)

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
            "href" => "#{Elektrine.ActivityPub.instance_url()}/tags/#{tag}"
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

    community_uri = get_community_uri_from_chain(message)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => object_id,
      "type" => "Question",
      "attributedTo" => "#{base_url}/users/#{user.username}",
      "name" => poll.question,
      "content" => poll_content(message, poll),
      "published" => format_datetime(message.inserted_at),
      "endTime" => poll_end_time(poll),
      "closed" => format_datetime(poll.closes_at),
      "votersCount" => poll_voters_count(poll),
      poll_choice_key(poll) => build_poll_options(poll),
      "to" => build_to_addresses(message, user, community_uri),
      "cc" => build_cc_addresses(message, user),
      "attachment" => build_attachments(message),
      "tag" => build_tags(message),
      "url" => object_id,
      "inReplyTo" => build_in_reply_to(message),
      "sensitive" => message.sensitive || false
    }
    |> maybe_put("audience", community_uri)
    |> maybe_put("updated", format_datetime(message.edited_at))
    |> maybe_add_content_warning(message)
    |> maybe_add_quote_url(message)
  end

  @doc """
  Builds a Question object for a local community poll.
  """
  def build_community_question(%Message{} = post, %Conversation{} = community, poll, opts \\ []) do
    base_url = get_builder_opt(opts, :base_url, ActivityPub.instance_url())
    community_actor_url = ActivityPub.community_actor_uri(community.name, base_url)
    post_id = ActivityPub.community_post_uri(community.name, post.id, base_url)

    author_uri =
      case get_builder_opt(opts, :author_uri) do
        value when is_binary(value) and value != "" ->
          value

        _ ->
          case post.sender do
            %{username: username} -> "#{base_url}/users/#{username}"
            _ -> community_actor_url
          end
      end

    %{
      "id" => post_id,
      "type" => "Question",
      "attributedTo" => author_uri,
      "name" => post.title || poll.question,
      "content" => poll_content(post, poll),
      "mediaType" => "text/html",
      "published" => format_datetime(post.inserted_at),
      "endTime" => poll_end_time(poll),
      "closed" => format_datetime(poll.closes_at),
      "votersCount" => poll_voters_count(poll),
      poll_choice_key(poll) => build_poll_options(poll),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => community_cc_addresses(post, community_actor_url),
      "attachment" => build_attachments(post),
      "tag" => build_tags(post),
      "audience" => community_actor_url,
      "url" => ActivityPub.community_post_web_url(community.name, post.id, base_url),
      "inReplyTo" => build_community_in_reply_to(post, community, base_url),
      "sensitive" => post.sensitive || false,
      "context" => community_actor_url,
      "commentsEnabled" => is_nil(post.locked_at),
      "stickied" => post.is_pinned || false,
      "distinguished" => false
    }
    |> maybe_put("updated", format_datetime(post.edited_at))
    |> maybe_put("summary", post.content_warning)
    |> maybe_add_quote_url(post)
  end

  @doc """
  Builds a Create activity for a local community object.
  """
  def build_community_create_activity(%Message{} = post, %Conversation{} = community, object) do
    base_url = ActivityPub.instance_url()

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{object["id"]}/activity",
      "type" => "Create",
      "actor" => ActivityPub.community_actor_uri(community.name, base_url),
      "published" => format_datetime(post.inserted_at),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => community_create_cc_addresses(post, community, base_url),
      "object" => object
    }
  end

  defp build_community_in_reply_to(%Message{reply_to_id: nil}, _community, _base_url), do: nil

  defp build_community_in_reply_to(%Message{reply_to_id: reply_to_id}, community, base_url) do
    case Elektrine.Messaging.get_message(reply_to_id) do
      %Message{activitypub_id: activitypub_id}
      when is_binary(activitypub_id) and activitypub_id != "" ->
        activitypub_id

      %Message{id: parent_id} ->
        ActivityPub.community_post_uri(community.name, parent_id, base_url)

      _ ->
        nil
    end
  end

  defp get_builder_opt(opts, key, default \\ nil)

  defp get_builder_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_builder_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, default)
  end

  defp get_builder_opt(_, _, default), do: default

  defp community_cc_addresses(%Message{} = post, community_actor_url) do
    [community_actor_url | mention_uris_for_message(post)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp community_create_cc_addresses(%Message{} = post, %Conversation{} = community, base_url) do
    [
      ActivityPub.community_followers_uri(community.name, base_url)
      | mention_uris_for_message(post)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp mention_uris_for_message(%Message{content: content}) when is_binary(content),
    do: Elektrine.ActivityPub.Mentions.get_mention_uris(content)

  defp mention_uris_for_message(_), do: []

  defp poll_content(%Message{} = message, poll) do
    case format_content(message) do
      "" -> format_html_content(poll.question)
      content -> content
    end
  end

  defp build_poll_options(poll) do
    poll.options
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn option ->
      %{
        "type" => "Note",
        "name" => option.option_text,
        "replies" => %{
          "type" => "Collection",
          "totalItems" => option.vote_count || 0
        }
      }
    end)
  end

  defp poll_choice_key(poll) do
    if poll.allow_multiple, do: "anyOf", else: "oneOf"
  end

  defp poll_voters_count(poll) do
    poll.voters_count || poll.total_votes || 0
  end

  defp poll_end_time(poll) do
    if poll.closes_at do
      format_datetime(poll.closes_at)
    else
      DateTime.add(DateTime.utc_now(), 24 * 3600, :second) |> DateTime.to_iso8601()
    end
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
  Builds a Move activity for account migration.
  """
  def build_move_activity(%User{}, old_actor_uri, new_actor_uri)
      when is_binary(old_actor_uri) and is_binary(new_actor_uri) do
    base_url = actor_base_url_from_uri(old_actor_uri) || ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Move",
      "actor" => old_actor_uri,
      "object" => old_actor_uri,
      "target" => new_actor_uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["#{old_actor_uri}/followers"],
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
  def build_delete_activity(actor_or_user, object_uri, former_type \\ "Note", opts \\ [])

  def build_delete_activity(%User{} = user, object_uri, former_type, opts) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"
    {to, cc} = activity_audience(nil, opts, ["https://www.w3.org/ns/activitystreams#Public"], [])

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
      "object" => tombstone
    }
    |> maybe_put_list("to", to)
    |> maybe_put_list("cc", cc)
  end

  def build_delete_activity(
        %Elektrine.ActivityPub.Actor{} = actor,
        object_uri,
        former_type,
        opts
      ) do
    activity_id = "#{actor.uri}/activities/#{Ecto.UUID.generate()}"
    {to, cc} = activity_audience(nil, opts, ["https://www.w3.org/ns/activitystreams#Public"], [])

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
      "actor" => actor.uri,
      "object" => tombstone
    }
    |> maybe_put_list("to", to)
    |> maybe_put_list("cc", cc)
  end

  @doc """
  Builds an Update activity (for profile or post updates).
  """
  def build_update_activity(actor_or_user, object, opts \\ [])

  def build_update_activity(%User{} = user, object, opts) do
    base_url = ActivityPub.instance_url()
    activity_id = "#{base_url}/activities/#{Ecto.UUID.generate()}"

    {to, cc} =
      activity_audience(object, opts, ["https://www.w3.org/ns/activitystreams#Public"], [])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Update",
      "actor" => "#{base_url}/users/#{user.username}",
      "object" => object
    }
    |> maybe_put_list("to", to)
    |> maybe_put_list("cc", cc)
  end

  def build_update_activity(%Elektrine.ActivityPub.Actor{} = actor, object, opts) do
    activity_id = "#{actor.uri}/activities/#{Ecto.UUID.generate()}"

    {to, cc} =
      activity_audience(object, opts, ["https://www.w3.org/ns/activitystreams#Public"], [])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Update",
      "actor" => actor.uri,
      "object" => object
    }
    |> maybe_put_list("to", to)
    |> maybe_put_list("cc", cc)
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp activity_audience(object, opts, default_to, default_cc) do
    to =
      select_audience(
        get_builder_opt(opts, :to, object_audience(object, "to")),
        default_to
      )

    cc =
      select_audience(
        get_builder_opt(opts, :cc, object_audience(object, "cc")),
        default_cc
      )

    {to, cc}
  end

  defp object_audience(object, field) when is_map(object), do: Map.get(object, field)
  defp object_audience(_object, _field), do: nil

  defp select_audience(value, fallback) do
    case normalize_audience(value) do
      [] -> normalize_audience(fallback)
      audience -> audience
    end
  end

  defp normalize_audience(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp normalize_audience(value) when is_binary(value) do
    if String.trim(value) == "" do
      []
    else
      [value]
    end
  end

  defp normalize_audience(_value), do: []

  defp maybe_put_list(map, _key, values) when values in [nil, []], do: map

  defp maybe_put_list(map, key, values) when is_list(values) do
    normalized =
      values
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    if normalized == [] do
      map
    else
      Map.put(map, key, normalized)
    end
  end

  defp actor_base_url_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        if is_nil(port) do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end

      _ ->
        nil
    end
  end

  defp actor_base_url_from_uri(_), do: nil

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
