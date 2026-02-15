defmodule Elektrine.ActivityPub.Handlers.CreateHandler do
  @moduledoc """
  Handles Create ActivityPub activities for Notes, Pages, Articles, and Questions.
  """

  require Logger

  import Ecto.Query

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.Emojis
  alias Elektrine.Messaging
  alias Elektrine.Social

  @doc """
  Handles an incoming Create activity.
  """
  def handle(%{"object" => object}, actor_uri, _target_user) when is_map(object) do
    author_uri = object["attributedTo"] || actor_uri

    case object["type"] do
      "Note" -> create_note(object, author_uri)
      "Page" -> create_note(object, author_uri)
      "Article" -> create_note(object, author_uri)
      "Question" -> create_question(object, author_uri)
      # Akkoma/Pleroma explicitly sends Answer type for poll votes
      "Answer" -> handle_incoming_poll_vote(object, author_uri)
      _ -> {:ok, :unhandled}
    end
  end

  @doc """
  Creates a note from an ActivityPub object.
  Public API for use by other handlers (e.g., AnnounceHandler).
  """
  def create_note(object, actor_uri) do
    if is_poll_vote?(object) do
      handle_incoming_poll_vote(object, actor_uri)
    else
      create_regular_note(object, actor_uri)
    end
  end

  @doc """
  Creates a Question (poll) from an ActivityPub object.
  """
  def create_question(object, actor_uri) do
    with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
      content = strip_html(object["content"] || object["question"] || "")
      hashtags = extract_hashtags(object, content)

      %URI{host: instance_domain} = URI.parse(actor_uri)
      Task.start(fn -> Emojis.process_activitypub_tags(object["tag"], instance_domain) end)

      visibility = determine_visibility(object)

      if visibility in ["public", "unlisted"] do
        options = extract_poll_options(object)
        {media_urls, alt_texts} = extract_media_with_alt_text(object)

        case Messaging.create_federated_message(%{
               content: content,
               visibility: visibility,
               activitypub_id: object["id"],
               activitypub_url: object["url"] || object["id"],
               federated: true,
               remote_actor_id: remote_actor.id,
               media_urls: media_urls,
               media_metadata:
                 if(map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}),
               inserted_at: Helpers.parse_published_date(object["published"]),
               extracted_hashtags: hashtags,
               post_type: "poll",
               like_count: Helpers.extract_interaction_count(object, "likes"),
               reply_count: Helpers.extract_interaction_count(object, "replies"),
               share_count: Helpers.extract_interaction_count(object, "shares"),
               sensitive: object["sensitive"] || false,
               content_warning: object["summary"]
             }) do
          {:ok, message} ->
            if options != [] do
              create_federated_poll(message.id, object, options)
            end

            if hashtags != [] do
              Task.start(fn -> link_hashtags_to_message(message.id, hashtags) end)
            end

            reloaded_message =
              Elektrine.Repo.preload(
                message,
                [:remote_actor, :sender, :link_preview, :hashtags, poll: [options: []]],
                force: true
              )

            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "timeline:public",
              {:new_public_post, reloaded_message}
            )

            {:ok, message}

          {:error, %Ecto.Changeset{errors: [activitypub_id: {"has already been taken", _}]}} ->
            {:ok, :already_exists}

          {:error, reason} ->
            Logger.error("Failed to create federated poll: #{inspect(reason)}")
            {:error, :failed_to_create_poll}
        end
      else
        {:ok, :ignored_non_public}
      end
    end
  end

  # Private functions

  defp is_poll_vote?(object) do
    has_name = is_binary(object["name"]) && String.trim(object["name"]) != ""
    has_reply_to = object["inReplyTo"] != nil
    content = object["content"] || ""
    has_minimal_content = String.length(strip_html(content)) < 5

    has_name && has_reply_to && has_minimal_content
  end

  defp handle_incoming_poll_vote(object, actor_uri) do
    option_name = object["name"]
    in_reply_to = object["inReplyTo"]

    poll_post_uri =
      case in_reply_to do
        uri when is_binary(uri) -> uri
        %{"id" => id} -> id
        _ -> nil
      end

    if poll_post_uri do
      with {:ok, _remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
           {:ok, message} <- get_local_message_from_uri(poll_post_uri),
           poll when not is_nil(poll) <-
             Elektrine.Repo.get_by(Elektrine.Social.Poll, message_id: message.id) do
        poll = Elektrine.Repo.preload(poll, :options)

        matching_option =
          Enum.find(poll.options, fn opt ->
            String.downcase(String.trim(opt.option_text)) ==
              String.downcase(String.trim(option_name))
          end)

        if matching_option do
          Elektrine.Repo.update_all(
            from(o in Elektrine.Social.PollOption, where: o.id == ^matching_option.id),
            inc: [vote_count: 1]
          )

          Elektrine.Repo.update_all(
            from(p in Elektrine.Social.Poll, where: p.id == ^poll.id),
            inc: [total_votes: 1]
          )

          {:ok, :poll_vote_recorded}
        else
          {:ok, :option_not_found}
        end
      else
        nil ->
          {:ok, :not_a_poll}

        {:error, :message_not_found} ->
          {:ok, :message_not_found}

        {:error, reason} ->
          Logger.warning("Failed to process poll vote: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, :invalid_poll_vote}
    end
  end

  defp create_regular_note(object, actor_uri) do
    with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
      content = strip_html(object["content"] || "")
      hashtags = extract_hashtags(object, content)
      mentioned_local_users = extract_local_mentions(object)

      %URI{host: instance_domain} = URI.parse(actor_uri)
      Task.start(fn -> Emojis.process_activitypub_tags(object["tag"], instance_domain) end)

      reply_to_id = get_reply_to_message_id(object["inReplyTo"])
      quoted_message_id = get_quoted_message_id(object)
      visibility = determine_visibility(object)

      if visibility in ["public", "unlisted"] do
        {media_urls, alt_texts} = extract_media_with_alt_text(object)

        result =
          Messaging.create_federated_message(%{
            content: content,
            visibility: visibility,
            activitypub_id: object["id"],
            activitypub_url: object["url"] || object["id"],
            federated: true,
            remote_actor_id: remote_actor.id,
            reply_to_id: reply_to_id,
            quoted_message_id: quoted_message_id,
            media_urls: media_urls,
            media_metadata: build_metadata_with_engagement(alt_texts, object),
            inserted_at: Helpers.parse_published_date(object["published"]),
            extracted_hashtags: hashtags,
            like_count: Helpers.extract_interaction_count(object, "likes"),
            reply_count: Helpers.extract_interaction_count(object, "replies"),
            share_count: Helpers.extract_interaction_count(object, "shares"),
            sensitive: object["sensitive"] || false,
            content_warning: object["summary"]
          })

        case result do
          {:ok, message} ->
            handle_post_create_tasks(
              message,
              remote_actor,
              hashtags,
              reply_to_id,
              mentioned_local_users
            )

            {:ok, message}

          {:error, %Ecto.Changeset{errors: [activitypub_id: {"has already been taken", _}]}} ->
            {:ok, :already_exists}

          {:error, reason} ->
            Logger.error("Failed to create federated message: #{inspect(reason)}")
            {:error, :failed_to_create_message}
        end
      else
        {:ok, :ignored_non_public}
      end
    end
  end

  defp handle_post_create_tasks(
         message,
         remote_actor,
         hashtags,
         reply_to_id,
         mentioned_local_users
       ) do
    # Link to mirror community if from Group
    if remote_actor.actor_type == "Group" do
      Task.start(fn ->
        case Messaging.FederatedCommunities.create_or_get_mirror_community(remote_actor) do
          {:ok, _mirror} ->
            Messaging.FederatedCommunities.link_message_to_mirror(message.id, remote_actor.id)

          {:error, reason} ->
            Logger.warning("Failed to link to mirror community: #{inspect(reason)}")
        end
      end)
    end

    # Link hashtags
    if hashtags != [] do
      Task.start(fn -> link_hashtags_to_message(message.id, hashtags) end)
    end

    # Generate link preview
    Task.start(fn -> generate_link_preview_for_message(message) end)

    # Notify reply and increment parent's reply count
    if reply_to_id do
      # Increment reply count on parent (like Akkoma does)
      Elektrine.ActivityPub.SideEffects.increment_reply_count(reply_to_id)

      Task.start(fn ->
        Elektrine.Notifications.FederationNotifications.notify_remote_reply(
          message.id,
          remote_actor.id
        )
      end)
    end

    # Notify mentions
    if mentioned_local_users != [] do
      Task.start(fn ->
        notify_mentioned_users(mentioned_local_users, message.id, remote_actor.id)
      end)
    end

    # Broadcast to timelines
    reloaded_message =
      Elektrine.Repo.preload(message, [:remote_actor, :sender, :link_preview, :hashtags],
        force: true
      )

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "timeline:public",
      {:new_public_post, reloaded_message}
    )
  end

  defp build_metadata_with_engagement(alt_texts, object) do
    base = if map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}

    # Store original engagement counts for reference
    engagement = %{
      "original_like_count" => Helpers.extract_interaction_count(object, "likes"),
      "original_reply_count" => Helpers.extract_interaction_count(object, "replies"),
      "original_share_count" => Helpers.extract_interaction_count(object, "shares")
    }

    # Store reply context for display when we don't have the parent locally
    reply_context = build_reply_context(object)

    # Extract external link for Lemmy link posts
    external_link = extract_external_link(object)

    base
    |> Map.merge(engagement)
    |> Map.merge(reply_context)
    |> Map.merge(external_link)
  end

  # Extract external link from Lemmy/other link posts
  # Lemmy stores the submitted URL in attachment with type "Link"
  defp extract_external_link(object) do
    attachments = object["attachment"] || []

    # Look for Link type attachment (Lemmy link posts)
    link_attachment =
      Enum.find(attachments, fn att ->
        att["type"] == "Link" && is_binary(att["href"])
      end)

    cond do
      # Found a Link attachment
      link_attachment && link_attachment["href"] ->
        %{"external_link" => link_attachment["href"]}

      # Check source field (some implementations use this)
      is_map(object["source"]) && is_binary(object["source"]["url"]) ->
        %{"external_link" => object["source"]["url"]}

      # No external link found
      true ->
        %{}
    end
  end

  # Extract reply context from the ActivityPub object for display purposes
  defp build_reply_context(object) do
    in_reply_to = object["inReplyTo"]

    cond do
      # No reply - not a reply post
      is_nil(in_reply_to) ->
        %{}

      # Simple URL string
      is_binary(in_reply_to) ->
        %{
          "inReplyTo" => in_reply_to,
          "inReplyToAuthor" => extract_author_from_url(in_reply_to)
        }

      # Object with id
      is_map(in_reply_to) && in_reply_to["id"] ->
        author =
          in_reply_to["attributedTo"] ||
            in_reply_to["actor"] ||
            extract_author_from_url(in_reply_to["id"])

        %{
          "inReplyTo" => in_reply_to["id"],
          "inReplyToAuthor" => normalize_author(author),
          "inReplyToContent" => extract_reply_content_preview(in_reply_to)
        }

      true ->
        %{}
    end
  end

  # Extract author handle from URL (fallback)
  defp extract_author_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> "someone on #{host}"
      _ -> nil
    end
  end

  defp extract_author_from_url(_), do: nil

  # Normalize author to a display string
  defp normalize_author(author) when is_binary(author) do
    if String.starts_with?(author, "http") do
      # It's a URL, try to extract username
      case URI.parse(author) do
        %{host: host, path: path} when is_binary(path) ->
          # Try to get username from path like /users/username or /@username
          case String.split(path, "/") |> Enum.filter(&(&1 != "")) do
            [_, username | _] when is_binary(username) ->
              "@#{String.replace_prefix(username, "@", "")}@#{host}"

            _ ->
              "someone on #{host}"
          end

        _ ->
          author
      end
    else
      author
    end
  end

  defp normalize_author(%{"id" => id}), do: normalize_author(id)
  defp normalize_author(_), do: nil

  # Extract a short content preview from the parent post if available
  defp extract_reply_content_preview(%{"content" => content}) when is_binary(content) do
    content
    |> strip_html()
    |> String.slice(0, 200)
  end

  defp extract_reply_content_preview(_), do: nil

  defp extract_poll_options(object) do
    options = object["oneOf"] || object["anyOf"] || []

    Enum.with_index(options)
    |> Enum.map(fn {option, index} ->
      votes = extract_vote_count(option)
      %{text: option["name"], votes: votes, position: index}
    end)
  end

  defp extract_vote_count(option) do
    case option["replies"] do
      %{"totalItems" => count} when is_integer(count) ->
        count

      %{"totalItems" => count} when is_binary(count) ->
        String.to_integer(count)

      %{} = replies ->
        replies["totalItems"] || 0

      url when is_binary(url) ->
        case Elektrine.ActivityPub.Fetcher.fetch_object(url) do
          {:ok, %{"totalItems" => count}} when is_integer(count) -> count
          {:ok, %{"totalItems" => count}} when is_binary(count) -> String.to_integer(count)
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp create_federated_poll(message_id, object, options) do
    end_time =
      case object["endTime"] || object["closed"] do
        nil -> nil
        time_str -> Helpers.parse_published_date(time_str)
      end

    allow_multiple = !is_nil(object["anyOf"])
    voters_count = extract_voters_count(object, options)

    poll_attrs = %{
      message_id: message_id,
      question: strip_html(object["content"] || ""),
      total_votes: voters_count,
      closes_at: end_time,
      allow_multiple: allow_multiple
    }

    poll_struct = :erlang.apply(Elektrine.Social.Poll, :__struct__, [])

    case Elektrine.Repo.insert(Elektrine.Social.Poll.changeset(poll_struct, poll_attrs)) do
      {:ok, poll} ->
        Enum.each(options, fn option ->
          option_struct = :erlang.apply(Elektrine.Social.PollOption, :__struct__, [])

          option_attrs = %{
            poll_id: poll.id,
            option_text: option.text,
            vote_count: option.votes,
            position: option[:position] || 0
          }

          option_struct
          |> Elektrine.Social.PollOption.changeset(option_attrs)
          |> Elektrine.Repo.insert()
        end)

        {:ok, poll}

      {:error, reason} ->
        Logger.error("Failed to create federated poll: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_voters_count(object, options) do
    case object["votersCount"] do
      count when is_integer(count) and count > 0 ->
        count

      count when is_binary(count) ->
        case Integer.parse(count) do
          {n, _} when n > 0 -> n
          _ -> sum_option_votes(options)
        end

      _ ->
        sum_option_votes(options)
    end
  end

  defp sum_option_votes(options) do
    Enum.reduce(options, 0, fn opt, acc -> acc + (opt[:votes] || 0) end)
  end

  defp strip_html(html) do
    html
    |> extract_mentions_from_at_pattern()
    |> extract_mentions_from_users_pattern()
    |> extract_mentions_from_u_pattern()
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<p[^>]*>/, "\n")
    |> String.replace(~r/<\/p>/, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> HtmlEntities.decode()
    |> String.trim()
  end

  defp extract_mentions_from_at_pattern(html) do
    Regex.replace(
      ~r/<a[^>]*href=["']https?:\/\/([^\/\s"']+)\/@([^\/\s"'#]+)["'][^>]*>.*?<\/a>/,
      html,
      fn _, domain, username -> "@#{username}@#{domain}" end
    )
  end

  defp extract_mentions_from_users_pattern(html) do
    Regex.replace(
      ~r/<a[^>]*href=["']https?:\/\/([^\/\s"']+)\/users\/([^\/\s"'#]+)["'][^>]*>.*?<\/a>/i,
      html,
      fn _, domain, username -> "@#{username}@#{domain}" end
    )
  end

  defp extract_mentions_from_u_pattern(html) do
    Regex.replace(
      ~r/<a[^>]*href=["']https?:\/\/([^\/\s"']+)\/u\/([^\/\s"'#]+)["'][^>]*>.*?<\/a>/i,
      html,
      fn _, domain, username -> "@#{username}@#{domain}" end
    )
  end

  defp determine_visibility(object) do
    to = object["to"] || []
    cc = object["cc"] || []
    public_address = "https://www.w3.org/ns/activitystreams#Public"

    cond do
      public_address in to -> "public"
      public_address in cc -> "unlisted"
      true -> "followers"
    end
  end

  defp get_reply_to_message_id(nil), do: nil

  defp get_reply_to_message_id(in_reply_to) when is_binary(in_reply_to) do
    case Messaging.get_message_by_activitypub_ref(in_reply_to) do
      nil -> nil
      message -> message.id
    end
  end

  defp get_reply_to_message_id(in_reply_to) when is_map(in_reply_to) do
    case Map.get(in_reply_to, "id") do
      nil -> nil
      id -> get_reply_to_message_id(id)
    end
  end

  defp get_reply_to_message_id(_), do: nil

  defp get_quoted_message_id(object) do
    quote_url = object["quoteUrl"] || object["_misskey_quote"] || object["quoteUri"]

    case quote_url do
      nil ->
        nil

      url when is_binary(url) ->
        case Messaging.get_message_by_activitypub_id(url) do
          nil ->
            nil

          message ->
            Task.start(fn -> Messaging.increment_quote_count(message.id) end)
            message.id
        end

      _ ->
        nil
    end
  end

  defp extract_media_with_alt_text(object) do
    attachments = object["attachment"] || []

    attachments
    |> Enum.with_index()
    |> Enum.map(fn {attachment, idx} ->
      url =
        cond do
          is_binary(attachment["url"]) -> attachment["url"]
          is_map(attachment["url"]) -> attachment["url"]["href"]
          is_binary(attachment["href"]) -> attachment["href"]
          true -> nil
        end

      alt_text = attachment["name"] || attachment["summary"] || attachment["content"]
      {url, alt_text, idx}
    end)
    |> Enum.filter(fn {url, _alt, _idx} -> is_binary(url) && valid_media_url?(url) end)
    |> Enum.take(10)
    |> Enum.reduce({[], %{}}, fn {url, alt_text, idx}, {urls, alt_map} ->
      new_urls = urls ++ [url]

      new_alt_map =
        if alt_text && String.trim(alt_text) != "" do
          Map.put(alt_map, to_string(idx), String.trim(alt_text))
        else
          alt_map
        end

      {new_urls, new_alt_map}
    end)
  end

  defp valid_media_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    valid_scheme = uri.scheme in ["https", "http"]
    has_host = uri.host != nil
    not_localhost = uri.host && !String.contains?(uri.host, "localhost")
    not_private_ip = uri.host && !is_private_ip?(uri.host)
    is_media = is_media_url?(url)

    valid_scheme && has_host && not_localhost && not_private_ip && is_media
  end

  defp valid_media_url?(_), do: false

  defp is_media_url?(url) when is_binary(url) do
    url_lower = String.downcase(url)

    has_media_extension =
      String.match?(
        url_lower,
        ~r/\.(jpe?g|png|gif|webp|svg|bmp|ico|avif|mp4|webm|ogv|mov|mp3|wav|ogg|m4a|flac)(\?.*)?$/
      )

    is_known_media_host =
      String.match?(
        url_lower,
        ~r/(\/media\/|\/images\/|\/uploads\/|\/files\/|\/attachments\/|\/pictrs\/|i\.imgur|pbs\.twimg|cdn\.discordapp|media\.tenor|i\.redd\.it|preview\.redd\.it)/
      )

    has_media_extension || is_known_media_host
  end

  defp is_media_url?(_), do: false

  defp is_private_ip?(host) do
    String.starts_with?(host, ["127.", "192.168.", "10.", "0."]) ||
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./, host) ||
      String.starts_with?(host, ["::1", "fc00:", "fd00:", "fe80:", "::ffff:", "100.64."]) ||
      host in ["localhost", "localhost.localdomain"]
  end

  defp extract_local_mentions(object) do
    case object["tag"] do
      tags when is_list(tags) ->
        tags
        |> Enum.filter(fn tag -> tag["type"] == "Mention" end)
        |> Enum.map(fn tag ->
          case extract_local_username_from_uri(tag["href"]) do
            {:ok, username} -> username
            _ -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp extract_local_username_from_uri(uri) when is_binary(uri) do
    Elektrine.ActivityPub.local_actor_prefixes()
    |> Enum.find_value({:error, :not_local}, fn prefix ->
      if String.starts_with?(uri, prefix) do
        username =
          uri
          |> String.replace_prefix(prefix, "")
          |> String.split(["/", "?", "#"], parts: 2)
          |> List.first()

        if is_binary(username) and username != "" do
          {:ok, username}
        else
          {:error, :not_local}
        end
      else
        nil
      end
    end)
  end

  defp extract_local_username_from_uri(_), do: {:error, :invalid_uri}

  defp notify_mentioned_users(usernames, message_id, remote_actor_id) do
    remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id)

    Enum.each(usernames, fn username ->
      case Elektrine.Accounts.get_user_by_username(username) do
        nil ->
          :ok

        user ->
          actor_name =
            if remote_actor do
              "@#{remote_actor.username}@#{remote_actor.domain}"
            else
              "a remote user"
            end

          Elektrine.Notifications.create_notification(%{
            user_id: user.id,
            type: "mention",
            title: "Mentioned in a post",
            body: "#{actor_name} mentioned you in a post",
            url: "/timeline/post/#{message_id}",
            source_type: "message",
            source_id: message_id,
            priority: "normal"
          })
      end
    end)
  end

  defp extract_hashtags(object, content) do
    tag_hashtags =
      case object["tag"] do
        tags when is_list(tags) ->
          tags
          |> Enum.filter(fn tag -> tag["type"] == "Hashtag" end)
          |> Enum.map(fn tag -> tag["name"] |> String.trim_leading("#") |> String.downcase() end)

        _ ->
          []
      end

    content_hashtags =
      Regex.scan(~r/#([a-zA-Z0-9_]+)/, content)
      |> Enum.map(fn [_, tag] -> String.downcase(tag) end)

    (tag_hashtags ++ content_hashtags) |> Enum.uniq() |> Enum.take(10)
  end

  defp generate_link_preview_for_message(message) do
    # First check for external_link in metadata (Lemmy link posts)
    # Then fall back to extracting from content
    external_link = get_in(message.media_metadata || %{}, ["external_link"])

    content_urls =
      if message.content && String.trim(message.content) != "" do
        Elektrine.Social.LinkPreviewFetcher.extract_urls(message.content)
      else
        []
      end

    url = external_link || List.first(content_urls)

    case url do
      nil ->
        :ok

      url ->
        try do
          metadata = Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(url)

          case metadata do
            %{status: "success"} ->
              preview_struct = :erlang.apply(Social.LinkPreview, :__struct__, [])

              preview_changeset =
                Social.LinkPreview.changeset(preview_struct, %{
                  url: url,
                  title: metadata.title,
                  description: metadata.description,
                  image_url: metadata.image_url,
                  favicon_url: metadata.favicon_url,
                  site_name: metadata.site_name,
                  status: "success",
                  fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
                })

              case Elektrine.Repo.insert(preview_changeset) do
                {:ok, preview} ->
                  Messaging.update_message(message, %{link_preview_id: preview.id})

                {:error, _} ->
                  :ok
              end

            _ ->
              :ok
          end
        rescue
          e ->
            Logger.warning("Failed to generate link preview: #{inspect(e)}")
            :ok
        end
    end
  end

  defp link_hashtags_to_message(message_id, hashtag_names) do
    hashtags =
      Enum.map(hashtag_names, fn name -> Social.get_or_create_hashtag(name) end)
      |> Enum.filter(&(&1 != nil))

    if hashtags != [] do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      associations =
        Enum.map(hashtags, fn hashtag ->
          %{message_id: message_id, hashtag_id: hashtag.id, inserted_at: now}
        end)

      Elektrine.Repo.insert_all(Social.PostHashtag, associations, on_conflict: :nothing)

      Enum.each(hashtags, fn hashtag -> Social.increment_hashtag_usage(hashtag.id) end)
    end
  end

  defp get_local_message_from_uri(uri) do
    base_url = ActivityPub.instance_url()

    cond do
      String.starts_with?(uri, "#{base_url}/posts/") ->
        id = String.replace_prefix(uri, "#{base_url}/posts/", "")
        get_message_by_id(id)

      String.match?(uri, ~r{#{base_url}/users/[^/]+/posts/}) ->
        id = uri |> String.split("/posts/") |> List.last()
        get_message_by_id(id)

      true ->
        case Messaging.get_message_by_activitypub_id(uri) do
          nil -> {:error, :message_not_found}
          message -> {:ok, message}
        end
    end
  end

  defp get_message_by_id(id) do
    case Messaging.get_message(id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end
end
