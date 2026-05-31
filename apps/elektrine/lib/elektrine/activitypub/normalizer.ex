defmodule Elektrine.ActivityPub.Normalizer do
  @moduledoc """
  Converts raw ActivityPub objects into internal message payloads.

  Raw ActivityPub maps should be normalized at this federation boundary before
  create/update handlers persist or render their fields.
  """

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.ActivityPub.RemoteFetch
  alias Elektrine.ActivityPub.Visibility
  alias Elektrine.Async
  alias Elektrine.Messaging

  @user_actor_path_markers [
    "/users/",
    "/user/",
    "/u/",
    "/@",
    "/profile/",
    "/profiles/",
    "/accounts/"
  ]
  @community_path_markers ["/c/", "/m/", "/community/", "/communities/", "/groups/", "/g/"]

  @doc """
  Builds the internal payload used to persist or update federated Note-like objects.
  """
  def message_payload(object, actor_uri, opts \\ []) when is_map(object) do
    object = maybe_enrich_sparse_object(object, opts)
    content = strip_html(object["content"] || "", object["tag"])
    title = normalize_object_title(object["name"])
    hashtags = extract_hashtags(object, content)
    {media_urls, alt_texts} = extract_media_with_alt_text(object)
    primary_url = extract_primary_url(object)

    %{
      attrs:
        %{
          content: content,
          title: title,
          visibility: determine_visibility(object, opts),
          activitypub_id: object["id"],
          activitypub_url: object["url"] || object["id"],
          primary_url: primary_url,
          media_urls: media_urls,
          media_metadata:
            build_metadata_with_engagement(
              alt_texts,
              object,
              Keyword.put_new(opts, :author_uri, actor_uri)
            ),
          reply_to_id: get_reply_to_message_id(object["inReplyTo"]),
          quoted_message_id: get_quoted_message_id(object),
          inserted_at: Helpers.parse_published_date(object["published"]),
          extracted_hashtags: hashtags,
          like_count: Helpers.extract_interaction_count(object, "likes"),
          reply_count: Helpers.extract_interaction_count(object, "replies"),
          share_count: Helpers.extract_interaction_count(object, "shares"),
          quote_count: extract_quote_count(object),
          sensitive: object["sensitive"] || false,
          content_warning: object["summary"]
        }
        |> Map.merge(federated_context_attrs(opts))
        |> Map.merge(Helpers.extract_vote_totals(object)),
      hashtags: hashtags,
      mentioned_local_users: extract_local_mentions(object)
    }
  end

  @doc """
  Builds the internal payload used to persist or update federated Question polls.
  """
  def question_payload(object, actor_uri, opts \\ []) when is_map(object) do
    object = maybe_enrich_sparse_object(object, opts)
    content = strip_html(object["content"] || "", object["tag"])
    question = poll_question_text(object)
    hashtags = extract_hashtags(object, hashtag_source_content(content, question))
    {media_urls, alt_texts} = extract_media_with_alt_text(object)
    options = poll_options(object)

    %{
      attrs:
        %{
          content: content,
          visibility: determine_visibility(object, opts),
          activitypub_id: object["id"],
          activitypub_url: object["url"] || object["id"],
          media_urls: media_urls,
          media_metadata:
            build_poll_metadata(
              alt_texts,
              object,
              Keyword.put_new(opts, :author_uri, actor_uri)
            ),
          inserted_at: Helpers.parse_published_date(object["published"]),
          extracted_hashtags: hashtags,
          post_type: "poll",
          like_count: Helpers.extract_interaction_count(object, "likes"),
          reply_count: Helpers.extract_interaction_count(object, "replies"),
          share_count: Helpers.extract_interaction_count(object, "shares"),
          quote_count: extract_quote_count(object),
          sensitive: object["sensitive"] || false,
          content_warning: object["summary"]
        }
        |> Map.merge(federated_context_attrs(opts))
        |> Map.merge(Helpers.extract_vote_totals(object)),
      question: question,
      hashtags: hashtags,
      options: options
    }
  end

  @doc """
  Validates that an object's attributedTo value matches the verified actor URI.
  """
  def validate_object_author(object, actor_uri) when is_map(object) do
    attributed_actor_uris =
      object["attributedTo"]
      |> expand_uri_candidates()
      |> Enum.map(&normalize_uri/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    normalized_actor_uri = actor_ref_uri(actor_uri)

    cond do
      is_nil(normalized_actor_uri) ->
        {:error, :actor_mismatch}

      attributed_actor_uris == [] ->
        :ok

      normalized_actor_uri in attributed_actor_uris ->
        :ok

      true ->
        {:error, :actor_mismatch}
    end
  end

  def validate_object_author(_object, _actor_uri), do: {:error, :actor_mismatch}

  @doc """
  Extracts the actor URI from common ActivityPub object fields.
  """
  def actor_uri(object) when is_map(object) do
    actor_ref_uri(object["attributedTo"]) || actor_ref_uri(object["actor"])
  end

  def actor_uri(_), do: nil

  @doc """
  Extracts the first URI from an ActivityPub actor reference.

  Actor references may be strings, maps with `id`/`url`/`href`, or lists of
  those values. PeerTube commonly sends `attributedTo` as a list containing an
  account Person and a channel Group.
  """
  def actor_ref_uri(value) do
    value
    |> expand_uri_candidates()
    |> Enum.map(&normalize_uri/1)
    |> Enum.find(&is_binary/1)
  end

  @doc """
  Extracts normalized engagement counters from a raw ActivityPub object.
  """
  def engagement_counts(object) when is_map(object) do
    %{
      like_count: Helpers.extract_interaction_count(object, "likes"),
      reply_count: Helpers.extract_interaction_count(object, "replies"),
      share_count: Helpers.extract_interaction_count(object, "shares"),
      quote_count: extract_quote_count(object)
    }
    |> Map.merge(Helpers.extract_vote_totals(object))
  end

  def engagement_counts(_),
    do: %{
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      quote_count: 0,
      upvotes: 0,
      downvotes: 0,
      score: 0
    }

  @doc """
  Extracts raw interaction collection references through the normalization boundary.
  """
  def interaction_collection(object, :likes) when is_map(object),
    do: object["likes"] || object["favourites"] || object["favorites"]

  def interaction_collection(object, :shares) when is_map(object),
    do: object["shares"] || object["announces"] || object["reblogs"]

  def interaction_collection(object, :replies) when is_map(object),
    do: object["replies"] || object["comments"]

  def interaction_collection(_, _), do: nil

  @doc """
  Detects ActivityPub Answer-like poll vote objects encoded as minimal Notes.
  """
  def poll_vote?(object) when is_map(object) do
    has_name = Elektrine.Strings.present?(object["name"])
    has_reply_to = object["inReplyTo"] != nil
    content = object["content"] || ""
    has_minimal_content = String.length(strip_html(content, object["tag"])) < 5

    has_name && has_reply_to && has_minimal_content
  end

  def poll_vote?(_), do: false

  @doc """
  Extracts poll options from a Question object.
  """
  def poll_options(object) when is_map(object) do
    options = object["oneOf"] || object["anyOf"] || []

    Enum.with_index(options)
    |> Enum.map(fn {option, index} ->
      votes = extract_vote_count(option)
      %{text: option["name"], votes: votes, position: index}
    end)
  end

  def poll_options(_), do: []

  @doc """
  Extracts the display question text from a Question object.
  """
  def poll_question_text(object) when is_map(object) do
    [object["question"], object["name"], object["content"]]
    |> Enum.find_value("", fn value ->
      normalized = strip_html(value || "", object["tag"])
      if normalized == "", do: nil, else: normalized
    end)
  end

  def poll_question_text(_), do: ""

  @doc """
  Fetches fuller object data for sparse objects when safe to do so.
  """
  def enrich_sparse_object(%{"id" => id} = object) when is_binary(id) do
    if sparse_object_payload?(object) do
      case RemoteFetch.fetch_object(id) do
        {:ok, fetched} when is_map(fetched) ->
          merge_sparse_object_payload(object, fetched)

        _ ->
          object
      end
    else
      object
    end
  end

  def enrich_sparse_object(object), do: object

  @doc """
  Trims URI values and normalizes blank/non-string values to nil.
  """
  def normalize_uri(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_uri(_), do: nil

  defp maybe_enrich_sparse_object(object, opts) do
    if Keyword.get(opts, :enrich_sparse_object, true) do
      enrich_sparse_object(object)
    else
      object
    end
  end

  defp build_poll_metadata(alt_texts, object, opts) do
    base = if map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}

    base
    |> Map.merge(extract_remote_status_metadata(object))
    |> Map.merge(extract_community_metadata(object, opts))
  end

  defp build_metadata_with_engagement(alt_texts, object, opts) do
    base = if map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}

    engagement = %{
      "original_like_count" => Helpers.extract_interaction_count(object, "likes"),
      "original_reply_count" => Helpers.extract_interaction_count(object, "replies"),
      "original_share_count" => Helpers.extract_interaction_count(object, "shares")
    }

    base
    |> Map.merge(engagement)
    |> Map.merge(extract_remote_status_metadata(object))
    |> Map.merge(build_reply_context(object))
    |> Map.merge(extract_external_link(object))
    |> Map.merge(extract_community_metadata(object, opts))
  end

  defp extract_remote_status_metadata(object) when is_map(object) do
    %{}
    |> maybe_put_metadata(
      "emoji_reactions",
      object["emoji_reactions"] || get_in(object, ["pleroma", "emoji_reactions"]) ||
        misskey_emoji_reactions(object["reactions"])
    )
    |> maybe_put_metadata("quotes_count", extract_quote_count(object))
    |> maybe_put_metadata(
      "quote",
      object["quote"] || object["renote"] || get_in(object, ["pleroma", "quote"])
    )
    |> maybe_put_metadata(
      "quote_id",
      object["quote_id"] || object["renoteId"] || get_in(object, ["pleroma", "quote_id"])
    )
    |> maybe_put_metadata(
      "quote_url",
      object["quoteUrl"] || object["quoteUri"] || object["quote_url"] ||
        object["_misskey_quote"] ||
        get_in(object, ["pleroma", "quote_url"])
    )
    |> maybe_put_metadata("card", object["card"])
    |> maybe_put_metadata("application", object["application"] || object["app"])
    |> maybe_put_metadata("language", object["language"])
    |> maybe_put_metadata("indexable", object["indexable"])
    |> maybe_put_metadata("media_attachments", extract_media_attachments_metadata(object))
    |> maybe_put_metadata("pleroma", object["pleroma"])
    |> maybe_put_metadata("misskey", misskey_status_metadata(object))
  end

  defp extract_remote_status_metadata(_), do: %{}

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, _key, []), do: metadata
  defp maybe_put_metadata(metadata, _key, %{} = value) when map_size(value) == 0, do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp misskey_emoji_reactions(reactions) when is_map(reactions) do
    reactions
    |> Enum.map(fn {emoji, count} ->
      %{"name" => emoji, "count" => parse_nonnegative_count(count)}
    end)
    |> Enum.filter(&(&1["count"] > 0))
  end

  defp misskey_emoji_reactions(_), do: []

  defp misskey_status_metadata(object) when is_map(object) do
    object
    |> Map.take([
      "id",
      "createdAt",
      "cw",
      "visibility",
      "reactionAcceptance",
      "reactionCount",
      "reactions",
      "renoteCount",
      "repliesCount",
      "renoteId",
      "replyId",
      "uri",
      "url"
    ])
  end

  defp extract_community_metadata(object, opts) do
    case detect_community_actor_uri(object, opts) do
      uri when is_binary(uri) -> %{"community_actor_uri" => uri}
      _ -> %{}
    end
  end

  defp detect_community_actor_uri(object, opts) when is_map(object) and is_list(opts) do
    author_uri =
      actor_ref_uri(object["attributedTo"]) || actor_ref_uri(Keyword.get(opts, :author_uri))

    fallback_uri = normalize_uri(Keyword.get(opts, :fallback_community_uri))

    direct_candidate =
      object
      |> community_uri_candidates(fallback_uri)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(fn uri ->
        public_audience_uri?(uri) or
          collection_uri?(uri) or
          post_reference_uri?(uri) or
          uri == author_uri
      end)
      |> Enum.find(&community_actor_uri?/1)

    direct_candidate || community_uri_from_reply_chain(object["inReplyTo"])
  end

  defp detect_community_actor_uri(_, _), do: nil

  defp community_uri_candidates(object, fallback_uri) do
    [
      object["audience"],
      object["context"],
      object["to"],
      object["cc"],
      object["target"],
      fallback_uri
    ]
    |> Enum.flat_map(&expand_uri_candidates/1)
    |> Enum.map(&normalize_uri/1)
  end

  defp community_uri_from_reply_chain(in_reply_to) do
    with uri when is_binary(uri) <- extract_in_reply_to_uri(in_reply_to),
         %{} = parent_message <- Messaging.get_message_by_activitypub_ref(uri) do
      get_community_uri_from_chain(parent_message)
    else
      _ -> nil
    end
  end

  defp extract_in_reply_to_uri(in_reply_to) when is_binary(in_reply_to),
    do: normalize_uri(in_reply_to)

  defp extract_in_reply_to_uri(in_reply_to) when is_map(in_reply_to) do
    in_reply_to
    |> Map.get("id")
    |> extract_in_reply_to_uri()
  end

  defp extract_in_reply_to_uri(_), do: nil

  defp get_community_uri_from_chain(message, depth \\ 0)

  defp get_community_uri_from_chain(_message, depth) when depth > 10, do: nil

  defp get_community_uri_from_chain(message, depth) do
    current_uri =
      message
      |> Map.get(:media_metadata, %{})
      |> case do
        metadata when is_map(metadata) -> Map.get(metadata, "community_actor_uri")
        _ -> nil
      end
      |> normalize_uri()

    if is_binary(current_uri) && community_actor_uri?(current_uri) do
      current_uri
    else
      with reply_to_id when is_integer(reply_to_id) <- Map.get(message, :reply_to_id),
           %{} = parent <- Messaging.get_message(reply_to_id) do
        get_community_uri_from_chain(parent, depth + 1)
      else
        _ -> nil
      end
    end
  end

  defp expand_uri_candidates(value) when is_binary(value), do: [value]

  defp expand_uri_candidates(values) when is_list(values),
    do: Enum.flat_map(values, &expand_uri_candidates/1)

  defp expand_uri_candidates(%{"id" => id}) when is_binary(id), do: [id]

  defp expand_uri_candidates(map) when is_map(map) do
    map
    |> Map.take(["id", "url", "href"])
    |> Map.values()
    |> Enum.flat_map(&expand_uri_candidates/1)
  end

  defp expand_uri_candidates(_), do: []

  defp public_audience_uri?(uri) when is_binary(uri), do: Visibility.public_audience?(uri)
  defp public_audience_uri?(_), do: false

  defp collection_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        normalized = path |> String.downcase() |> String.trim_trailing("/")
        String.ends_with?(normalized, "/followers") || String.ends_with?(normalized, "/following")

      _ ->
        false
    end
  end

  defp collection_uri?(_), do: false

  defp post_reference_uri?(uri) when is_binary(uri) do
    Regex.match?(~r{/post/\d+(?:$|[/?#])}, uri) ||
      Regex.match?(~r{/c/[^/]+/p/\d+(?:$|[/?#])}, uri) ||
      Regex.match?(~r{/m/[^/]+/[pt]/\d+(?:$|[/?#])}, uri)
  end

  defp post_reference_uri?(_), do: false

  defp community_actor_uri?(uri) when is_binary(uri) do
    known_group_actor_uri?(uri) || community_path_uri?(uri)
  end

  defp community_actor_uri?(_), do: false

  defp known_group_actor_uri?(uri) when is_binary(uri) do
    case ActivityPub.get_actor_by_uri(uri) do
      %Elektrine.ActivityPub.Actor{actor_type: "Group"} -> true
      _ -> false
    end
  end

  defp known_group_actor_uri?(_), do: false

  defp community_path_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        path_downcased = String.downcase(path)

        Enum.any?(@community_path_markers, &String.contains?(path_downcased, &1)) &&
          !user_actor_uri?(uri)

      _ ->
        false
    end
  end

  defp community_path_uri?(_), do: false

  defp user_actor_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        downcased_path = String.downcase(path)
        Enum.any?(@user_actor_path_markers, &String.contains?(downcased_path, &1))

      _ ->
        false
    end
  end

  defp user_actor_uri?(_), do: false

  defp extract_external_link(object) do
    activity_id = normalize_external_link_candidate(object["id"])

    submitted_link =
      [
        extract_attachment_link(object["attachment"]),
        extract_url_field_link(object["url"], activity_id),
        extract_source_field_link(object["source"], activity_id)
      ]
      |> Enum.find(&is_binary/1)

    if is_binary(submitted_link), do: %{"external_link" => submitted_link}, else: %{}
  end

  defp extract_primary_url(object) do
    case extract_external_link(object) do
      %{"external_link" => url} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp extract_attachment_link(attachments) when is_list(attachments) do
    attachments
    |> Enum.find_value(fn
      %{"type" => "Link"} = att ->
        normalize_external_link_candidate(
          att["href"] || att["url"] || get_in(att, ["url", "href"])
        )

      %{} = att ->
        normalize_external_link_candidate(att["href"])

      _ ->
        nil
    end)
  end

  defp extract_attachment_link(%{} = attachment), do: extract_attachment_link([attachment])
  defp extract_attachment_link(_), do: nil

  defp extract_url_field_link(url_field, activity_id) do
    url_field
    |> expand_external_link_candidates()
    |> Enum.find(fn candidate ->
      is_binary(candidate) and candidate != activity_id
    end)
  end

  defp extract_source_field_link(%{} = source, activity_id) do
    [source["url"], source["href"], source["content"]]
    |> expand_external_link_candidates()
    |> Enum.find(fn candidate ->
      is_binary(candidate) and candidate != activity_id
    end)
  end

  defp extract_source_field_link(_, _), do: nil

  defp expand_external_link_candidates(value) when is_list(value) do
    Enum.flat_map(value, &expand_external_link_candidates/1)
  end

  defp expand_external_link_candidates(%{"href" => href}),
    do: expand_external_link_candidates(href)

  defp expand_external_link_candidates(%{"url" => url}), do: expand_external_link_candidates(url)
  defp expand_external_link_candidates(%{href: href}), do: expand_external_link_candidates(href)
  defp expand_external_link_candidates(%{url: url}), do: expand_external_link_candidates(url)

  defp expand_external_link_candidates(value) when is_binary(value) do
    case normalize_external_link_candidate(value) do
      normalized when is_binary(normalized) -> [normalized]
      _ -> []
    end
  end

  defp expand_external_link_candidates(_), do: []

  defp normalize_external_link_candidate(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(parsed)

      _ ->
        nil
    end
  end

  defp normalize_external_link_candidate(_), do: nil

  defp build_reply_context(object) do
    in_reply_to = object["inReplyTo"]

    cond do
      is_nil(in_reply_to) ->
        %{}

      is_binary(in_reply_to) ->
        %{
          "inReplyTo" => in_reply_to,
          "inReplyToAuthor" => extract_reply_author(in_reply_to, object["tag"])
        }

      is_map(in_reply_to) && in_reply_to["id"] ->
        author =
          in_reply_to["attributedTo"] ||
            in_reply_to["actor"] ||
            extract_reply_author(in_reply_to["id"], object["tag"])

        %{
          "inReplyTo" => in_reply_to["id"],
          "inReplyToAuthor" => normalize_author(author),
          "inReplyToContent" => extract_reply_content_preview(in_reply_to)
        }

      true ->
        %{}
    end
  end

  defp extract_author_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(host) and is_binary(path) ->
        case extract_username_from_path(path) do
          username when is_binary(username) ->
            "@#{username}@#{host}"

          _ ->
            case extract_post_id_from_path(path) do
              post_id when is_binary(post_id) -> "post #{post_id} on #{host}"
              _ -> "a post on #{host}"
            end
        end

      %{host: host} when is_binary(host) ->
        "a post on #{host}"

      _ ->
        nil
    end
  end

  defp extract_author_from_url(_), do: nil

  defp extract_reply_author(in_reply_to_url, tags) when is_binary(in_reply_to_url) do
    extract_reply_author_from_tags(tags, in_reply_to_url) ||
      extract_author_from_url(in_reply_to_url)
  end

  defp extract_reply_author(_, _), do: nil

  defp extract_reply_author_from_tags(tags, in_reply_to_url) when is_list(tags) do
    handles =
      tags
      |> Enum.filter(fn tag -> is_map(tag) && tag["type"] == "Mention" end)
      |> Enum.map(&mention_tag_to_handle/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case handles do
      [] ->
        nil

      handles ->
        reply_host = extract_host_from_url(in_reply_to_url)

        if is_binary(reply_host) do
          Enum.find(handles, fn handle ->
            String.ends_with?(String.downcase(handle), "@#{String.downcase(reply_host)}")
          end) || hd(handles)
        else
          hd(handles)
        end
    end
  end

  defp extract_reply_author_from_tags(_, _), do: nil

  defp mention_tag_to_handle(tag) when is_map(tag) do
    name = tag["name"]
    href = tag["href"]
    host = extract_host_from_url(href)

    cond do
      is_binary(name) ->
        normalize_mention_name(name, host) || extract_author_from_url(href)

      is_binary(href) ->
        extract_author_from_url(href)

      true ->
        nil
    end
  end

  defp mention_tag_to_handle(_), do: nil

  defp normalize_mention_name(name, host) when is_binary(name) do
    cleaned = String.trim(name)

    cond do
      Regex.match?(~r/^@[^@\s]+@[^@\s]+$/, cleaned) ->
        cleaned

      Regex.match?(~r/^@[^@\s]+$/, cleaned) && is_binary(host) ->
        "#{cleaned}@#{host}"

      true ->
        nil
    end
  end

  defp normalize_mention_name(_, _), do: nil

  defp extract_host_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp extract_host_from_url(_), do: nil

  defp normalize_author(author) when is_binary(author) do
    if String.starts_with?(author, "http") do
      extract_author_from_url(author) || author
    else
      author
    end
  end

  defp normalize_author(%{"id" => id}), do: normalize_author(id)
  defp normalize_author(_), do: nil

  defp extract_username_from_path(path) when is_binary(path) do
    case path_segments(path) do
      ["users", username | _] ->
        sanitize_identifier(username)

      ["u", username | _] ->
        sanitize_identifier(username)

      ["profile", username | _] ->
        sanitize_identifier(username)

      ["accounts", username | _] ->
        sanitize_identifier(username)

      [segment | _] ->
        if String.starts_with?(segment, "@") do
          sanitize_identifier(segment)
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_username_from_path(_), do: nil

  defp extract_post_id_from_path(path) when is_binary(path) do
    candidate =
      case path_segments(path) do
        ["users", _username, "statuses", post_id | _] -> post_id
        ["notice", post_id | _] -> post_id
        ["objects", post_id | _] -> post_id
        ["posts", post_id | _] -> post_id
        ["post", post_id | _] -> post_id
        ["comment", post_id | _] -> post_id
        ["comments", post_id | _] -> post_id
        ["activities", post_id | _] -> post_id
        [first, post_id | _] -> if String.starts_with?(first, "@"), do: post_id, else: nil
        _ -> nil
      end

    sanitize_identifier(candidate)
  end

  defp extract_post_id_from_path(_), do: nil

  defp path_segments(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sanitize_identifier(value) when is_binary(value) do
    value
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      sanitized -> sanitized
    end
  end

  defp sanitize_identifier(_), do: nil

  defp extract_reply_content_preview(%{"content" => content, "tag" => tags})
       when is_binary(content) do
    content
    |> strip_html(tags)
    |> String.slice(0, 200)
  end

  defp extract_reply_content_preview(%{"content" => content}) when is_binary(content) do
    content
    |> strip_html()
    |> String.slice(0, 200)
  end

  defp extract_reply_content_preview(_), do: nil

  defp extract_vote_count(option) do
    case option["replies"] do
      %{"totalItems" => count} when is_integer(count) ->
        count

      %{"totalItems" => count} when is_binary(count) ->
        String.to_integer(count)

      %{} = replies ->
        replies["totalItems"] || 0

      url when is_binary(url) ->
        case RemoteFetch.fetch_object(url) do
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

  defp strip_html(html, tags \\ [])

  defp strip_html(nil, _tags), do: ""

  defp strip_html(html, tags) when is_binary(html) do
    html
    |> extract_mentions_from_at_pattern()
    |> extract_mentions_from_users_pattern()
    |> extract_mentions_from_u_pattern()
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<p[^>]*>/, "\n")
    |> String.replace(~r/<\/p>/, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> HtmlEntities.decode()
    |> expand_short_tag_mentions(tags)
    |> String.trim()
  end

  defp strip_html(_, _tags), do: ""

  defp normalize_object_title(title) when is_binary(title) do
    title
    |> strip_html()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_object_title(_), do: nil

  defp hashtag_source_content(content, question)
       when is_binary(content) and is_binary(question) do
    if Elektrine.Strings.present?(content), do: content, else: question
  end

  defp sparse_object_payload?(object) when is_map(object) do
    missing_name = blank_object_value?(object["name"])
    missing_content = blank_object_value?(object["content"])
    missing_attachment = blank_object_value?(object["attachment"])
    missing_image = blank_object_value?(object["image"])

    missing_name && missing_content && missing_attachment && missing_image
  end

  defp sparse_object_payload?(_), do: false

  defp merge_sparse_object_payload(base, fetched) when is_map(base) and is_map(fetched) do
    Enum.reduce(fetched, base, fn {key, fetched_value}, acc ->
      current_value = Map.get(acc, key)

      if blank_object_value?(current_value) and not blank_object_value?(fetched_value) do
        Map.put(acc, key, fetched_value)
      else
        acc
      end
    end)
  end

  defp merge_sparse_object_payload(base, _), do: base

  defp blank_object_value?(nil), do: true
  defp blank_object_value?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp blank_object_value?(value) when is_list(value), do: value == []
  defp blank_object_value?(value) when is_map(value), do: map_size(value) == 0
  defp blank_object_value?(_), do: false

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

  defp expand_short_tag_mentions(text, tags) when is_binary(text) and is_list(tags) do
    tags
    |> short_mention_replacements()
    |> Enum.reduce(text, fn {short, full}, acc ->
      Regex.replace(
        ~r/(^|[^A-Za-z0-9_@\/])#{Regex.escape(short)}(?![A-Za-z0-9_@])/u,
        acc,
        fn _, prefix -> "#{prefix}#{full}" end
      )
    end)
  end

  defp expand_short_tag_mentions(text, _tags), do: text

  defp short_mention_replacements(tags) when is_list(tags) do
    tags
    |> Enum.filter(fn tag -> is_map(tag) && tag["type"] == "Mention" end)
    |> Enum.reduce(%{}, fn tag, acc ->
      short = short_mention_name(tag["name"])
      full = mention_tag_to_handle(tag)

      if is_binary(short) and mention_handle?(full) and short != full do
        Map.update(acc, short, MapSet.new([full]), &MapSet.put(&1, full))
      else
        acc
      end
    end)
    |> Enum.reduce(%{}, fn {short, handles}, acc ->
      case MapSet.to_list(handles) do
        [full] -> Map.put(acc, short, full)
        _ -> acc
      end
    end)
  end

  defp short_mention_replacements(_), do: %{}

  defp short_mention_name(name) when is_binary(name) do
    cleaned = String.trim(name)

    if Regex.match?(~r/^@[^@\s]+$/, cleaned), do: cleaned, else: nil
  end

  defp short_mention_name(_), do: nil

  defp mention_handle?(handle) when is_binary(handle) do
    Regex.match?(~r/^@[^@\s]+@[^@\s]+$/, handle)
  end

  defp mention_handle?(_), do: false

  defp determine_visibility(object, opts) do
    visibility_opts = Keyword.take(opts, [:assume_public_reply_without_audience])
    Visibility.visibility(object, visibility_opts)
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
        case Messaging.get_message_by_activitypub_ref(url) do
          nil ->
            nil

          message ->
            Async.run(fn -> Messaging.increment_quote_count(message.id) end)
            message.id
        end

      _ ->
        nil
    end
  end

  defp extract_quote_count(object) when is_map(object) do
    parse_nonnegative_count(
      object["quotes_count"] ||
        object["quote_count"] ||
        object["quotesCount"] ||
        object["quoteCount"] ||
        object["quotedCount"] ||
        get_in(object, ["pleroma", "quotes_count"])
    )
  end

  defp extract_quote_count(_), do: 0

  defp parse_nonnegative_count(value) when is_integer(value), do: max(value, 0)

  defp parse_nonnegative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  defp parse_nonnegative_count(_), do: 0

  defp extract_media_attachments_metadata(object) when is_map(object) do
    attachments =
      case Map.get(object, "attachment", []) do
        [] -> Map.get(object, "files", [])
        attachments -> attachments
      end

    attachments
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} -> media_attachment_metadata(attachment, index) end)
    |> Enum.filter(& &1)
    |> Enum.take(10)
  end

  defp extract_media_attachments_metadata(_), do: []

  defp media_attachment_metadata(%{} = attachment, index) do
    url = attachment_url(attachment)

    if is_binary(url) && valid_media_url?(url) do
      %{
        "id" => to_string(index),
        "type" => mastodon_media_type(attachment, url),
        "url" => url,
        "preview_url" => attachment_preview_url(attachment) || attachment["thumbnailUrl"] || url,
        "remote_url" =>
          attachment["remote_url"] || attachment["remoteUrl"] || attachment["uri"] || url,
        "meta" => attachment["meta"] || attachment["properties"] || %{},
        "description" =>
          attachment["comment"] || attachment["name"] || attachment["summary"] ||
            attachment["content"],
        "blurhash" => attachment["blurhash"]
      }
    end
  end

  defp media_attachment_metadata(_, _), do: nil

  defp attachment_url(attachment) when is_map(attachment) do
    cond do
      is_binary(attachment["url"]) -> attachment["url"]
      is_binary(attachment["uri"]) -> attachment["uri"]
      is_map(attachment["url"]) -> attachment["url"]["href"]
      is_list(attachment["url"]) -> Enum.find_value(attachment["url"], &attachment_url/1)
      is_binary(attachment["href"]) -> attachment["href"]
      true -> nil
    end
  end

  defp attachment_url(_), do: nil

  defp attachment_preview_url(%{"preview_url" => url}) when is_binary(url), do: url
  defp attachment_preview_url(%{"previewUrl" => url}) when is_binary(url), do: url
  defp attachment_preview_url(%{"preview" => %{"url" => url}}) when is_binary(url), do: url
  defp attachment_preview_url(%{"preview" => %{"href" => url}}) when is_binary(url), do: url
  defp attachment_preview_url(_), do: nil

  defp mastodon_media_type(attachment, url) do
    media_type =
      String.downcase(
        to_string(attachment["mediaType"] || attachment["mimeType"] || attachment["type"] || "")
      )

    url_downcased = String.downcase(url)

    cond do
      String.starts_with?(media_type, "video/") -> "video"
      String.starts_with?(media_type, "audio/") -> "audio"
      String.starts_with?(media_type, "image/gif") -> "gifv"
      String.starts_with?(media_type, "image/") -> "image"
      String.match?(url_downcased, ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/) -> "video"
      String.match?(url_downcased, ~r/\.(mp3|wav|ogg|m4a|flac)(\?.*)?$/) -> "audio"
      String.match?(url_downcased, ~r/\.gif(\?.*)?$/) -> "gifv"
      true -> "image"
    end
  end

  defp extract_media_with_alt_text(object) do
    attachments = object["attachment"] || object["files"] || []

    attachments
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {attachment, idx} ->
      url =
        cond do
          is_binary(attachment["url"]) -> attachment["url"]
          is_binary(attachment["uri"]) -> attachment["uri"]
          is_map(attachment["url"]) -> attachment["url"]["href"]
          is_binary(attachment["thumbnailUrl"]) -> attachment["thumbnailUrl"]
          is_binary(attachment["href"]) -> attachment["href"]
          true -> nil
        end

      alt_text =
        attachment["comment"] || attachment["name"] || attachment["summary"] ||
          attachment["content"]

      {url, alt_text, idx}
    end)
    |> Enum.filter(fn {url, _alt, _idx} -> is_binary(url) && valid_media_url?(url) end)
    |> Enum.take(10)
    |> Enum.reduce({[], %{}}, fn {url, alt_text, idx}, {urls, alt_map} ->
      new_urls = urls ++ [url]

      new_alt_map =
        if Elektrine.Strings.present?(alt_text) do
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
    not_private_ip = uri.host && !private_ip?(uri.host)
    is_media = media_url?(url)

    valid_scheme && has_host && not_localhost && not_private_ip && is_media
  end

  defp valid_media_url?(_), do: false

  defp media_url?(url) when is_binary(url) do
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

  defp media_url?(_), do: false

  defp private_ip?(host) do
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
    ActivityPub.local_username_from_uri(uri)
  end

  defp extract_local_username_from_uri(_), do: {:error, :invalid_uri}

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

  defp federated_context_attrs(opts) do
    case Keyword.get(opts, :conversation_id) do
      conversation_id when is_integer(conversation_id) -> %{conversation_id: conversation_id}
      _ -> %{}
    end
  end
end
