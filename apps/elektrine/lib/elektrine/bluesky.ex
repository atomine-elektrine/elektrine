defmodule Elektrine.Bluesky do
  @moduledoc "Mirrors local public timeline posts to Bluesky (ATProto).\n\nThis bridge is intentionally best-effort:\n- It never raises to callers.\n- Failures are logged and skipped.\n- ActivityPub delivery remains independent.\n"
  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Uploads
  @post_collection "app.bsky.feed.post"
  @like_collection "app.bsky.feed.like"
  @repost_collection "app.bsky.feed.repost"
  @follow_collection "app.bsky.graph.follow"
  @images_embed_type "app.bsky.embed.images"
  @video_embed_type "app.bsky.embed.video"
  @external_embed_type "app.bsky.embed.external"
  @record_embed_type "app.bsky.embed.record"
  @record_with_media_embed_type "app.bsky.embed.recordWithMedia"
  @facet_link_type "app.bsky.richtext.facet#link"
  @facet_mention_type "app.bsky.richtext.facet#mention"
  @facet_tag_type "app.bsky.richtext.facet#tag"
  @default_max_chars 300
  @default_record_list_limit 100
  @default_timeout_ms 12_000
  @max_reply_depth 20
  @max_embed_images 4
  @max_alt_text_chars 1000
  @max_external_title_chars 100
  @max_external_description_chars 300
  @max_facets 30
  @local_media_prefixes [
    "timeline-attachments/",
    "chat-attachments/",
    "discussion-attachments/",
    "gallery-attachments/",
    "uploads/"
  ]
  @doc "Mirrors a local message to Bluesky when all bridge requirements are met.\n"
  def mirror_post(%Message{} = message) do
    with :ok <- ensure_bridge_enabled(),
         :ok <- ensure_mirrorable_message(message),
         {:ok, user} <- fetch_sender(message.sender_id),
         {:ok, text} <- build_post_text(message),
         {:ok, reply_payload} <- maybe_build_reply_payload(message.reply_to_id),
         {:ok, session} <- session_for_user(user),
         {:ok, record} <- build_record(message, text, reply_payload, session),
         {:ok, published} <-
           create_record(session.service_url, session.access_jwt, session.did, record) do
      persist_message_mapping(message.id, published)
    else
      {:skip, reason} ->
        {:skipped, reason}

      {:error, reason} ->
        Logger.warning("Bluesky mirror failed for message #{message.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Updates an already mirrored Bluesky post after a local edit.\n"
  def mirror_post_update(%Message{} = message) do
    with :ok <- ensure_bridge_enabled(),
         :ok <- ensure_updatable_message(message),
         {:ok, user} <- fetch_sender(message.sender_id),
         {:ok, text} <- build_post_text(message),
         {:ok, reply_payload} <- maybe_build_reply_payload(message.reply_to_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_uri} <- parse_at_uri(message.bluesky_uri),
         :ok <- ensure_collection(parsed_uri.collection, @post_collection),
         {:ok, record} <- build_record(message, text, reply_payload, session),
         {:ok, published} <-
           put_record(
             session.service_url,
             session.access_jwt,
             parsed_uri.repo,
             parsed_uri.collection,
             parsed_uri.rkey,
             record
           ) do
      persist_message_mapping_update(message.id, published)
    else
      {:skip, reason} ->
        {:skipped, reason}

      {:error, reason} ->
        Logger.warning(
          "Bluesky update mirror failed for message #{message.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Deletes an already mirrored Bluesky post after a local delete.\n"
  def mirror_post_delete(%Message{} = message) do
    with :ok <- ensure_bridge_enabled(),
         :ok <- ensure_deletable_message(message),
         {:ok, user} <- fetch_sender(message.sender_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_uri} <- parse_at_uri(message.bluesky_uri),
         :ok <- ensure_collection(parsed_uri.collection, @post_collection) do
      delete_record(
        session.service_url,
        session.access_jwt,
        parsed_uri.repo,
        parsed_uri.collection,
        parsed_uri.rkey
      )
    else
      {:skip, reason} ->
        {:skipped, reason}

      {:error, reason} ->
        Logger.warning(
          "Bluesky delete mirror failed for message #{message.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Mirrors a local like on a mirrored post to Bluesky.\n"
  def mirror_like(message_id, user_id) when is_integer(message_id) and is_integer(user_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, message} <- fetch_mirrored_subject_message(message_id),
         {:ok, user} <- fetch_user(user_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_subject} <- parse_at_uri(message.bluesky_uri),
         {:ok, existing_uri} <-
           find_subject_record_uri(session, @like_collection, parsed_subject.uri),
         {:ok, _published} <-
           maybe_create_subject_record(
             session,
             @like_collection,
             existing_uri,
             %{
               "$type" => @like_collection,
               "subject" => %{"uri" => message.bluesky_uri, "cid" => message.bluesky_cid},
               "createdAt" => format_created_at(DateTime.utc_now())
             }
           ) do
      :ok
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mirrors a local unlike by deleting the matching Bluesky like record.\n"
  def mirror_unlike(message_id, user_id) when is_integer(message_id) and is_integer(user_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, message} <- fetch_mirrored_subject_message(message_id),
         {:ok, user} <- fetch_user(user_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_subject} <- parse_at_uri(message.bluesky_uri),
         {:ok, like_uri} <- find_subject_record_uri(session, @like_collection, parsed_subject.uri) do
      maybe_delete_record_by_uri(session, @like_collection, like_uri)
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mirrors a local repost on a mirrored post to Bluesky.\n"
  def mirror_repost(message_id, user_id) when is_integer(message_id) and is_integer(user_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, message} <- fetch_mirrored_subject_message(message_id),
         {:ok, user} <- fetch_user(user_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_subject} <- parse_at_uri(message.bluesky_uri),
         {:ok, existing_uri} <-
           find_subject_record_uri(session, @repost_collection, parsed_subject.uri),
         {:ok, _published} <-
           maybe_create_subject_record(
             session,
             @repost_collection,
             existing_uri,
             %{
               "$type" => @repost_collection,
               "subject" => %{"uri" => message.bluesky_uri, "cid" => message.bluesky_cid},
               "createdAt" => format_created_at(DateTime.utc_now())
             }
           ) do
      :ok
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mirrors a local unrepost by deleting the matching Bluesky repost record.\n"
  def mirror_unrepost(message_id, user_id) when is_integer(message_id) and is_integer(user_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, message} <- fetch_mirrored_subject_message(message_id),
         {:ok, user} <- fetch_user(user_id),
         {:ok, session} <- session_for_user(user),
         {:ok, parsed_subject} <- parse_at_uri(message.bluesky_uri),
         {:ok, repost_uri} <-
           find_subject_record_uri(session, @repost_collection, parsed_subject.uri) do
      maybe_delete_record_by_uri(session, @repost_collection, repost_uri)
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mirrors a local follow relationship to Bluesky.\n"
  def mirror_follow(follower_id, followed_id)
      when is_integer(follower_id) and is_integer(followed_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, follower} <- fetch_user(follower_id),
         {:ok, followed} <- fetch_user(followed_id),
         {:ok, session} <- session_for_user(follower),
         {:ok, followed_did} <- resolve_follow_target_did(followed, session),
         {:ok, existing_uri} <- find_follow_record_uri(session, @follow_collection, followed_did),
         {:ok, _published} <-
           maybe_create_subject_record(
             session,
             @follow_collection,
             existing_uri,
             %{
               "$type" => @follow_collection,
               "subject" => followed_did,
               "createdAt" => format_created_at(DateTime.utc_now())
             }
           ) do
      :ok
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mirrors a local unfollow by deleting the matching Bluesky follow record.\n"
  def mirror_unfollow(follower_id, followed_id)
      when is_integer(follower_id) and is_integer(followed_id) do
    with :ok <- ensure_bridge_enabled(),
         {:ok, follower} <- fetch_user(follower_id),
         {:ok, followed} <- fetch_user(followed_id),
         {:ok, session} <- session_for_user(follower),
         {:ok, followed_did} <- resolve_follow_target_did(followed, session),
         {:ok, follow_uri} <- find_follow_record_uri(session, @follow_collection, followed_did) do
      maybe_delete_record_by_uri(session, @follow_collection, follow_uri)
    else
      {:skip, reason} -> {:skipped, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates a Bluesky session for a configured local user.\n"
  def session_for_user(%User{} = user) do
    with :ok <- ensure_bridge_enabled(),
         :ok <- ensure_user_enabled(user),
         {:ok, identifier} <- require_user_value(user.bluesky_identifier, :missing_identifier),
         {:ok, password} <- require_user_value(user.bluesky_app_password, :missing_app_password),
         {:ok, service_url} <- service_url_for(user),
         {:ok, session} <- create_session(service_url, identifier, password),
         :ok <- persist_user_did(user.id, session.did) do
      {:ok, Map.put(session, :service_url, service_url)}
    end
  end

  defp ensure_bridge_enabled do
    if Keyword.get(bluesky_config(), :enabled, false) do
      :ok
    else
      {:skip, :bridge_disabled}
    end
  end

  defp ensure_mirrorable_message(%Message{} = message) do
    cond do
      message.visibility != "public" -> {:skip, :not_public}
      message.federated -> {:skip, :remote_message}
      message.post_type == "message" -> {:skip, :not_timeline_post}
      is_nil(message.sender_id) -> {:skip, :missing_sender}
      is_binary(message.bluesky_uri) and message.bluesky_uri != "" -> {:skip, :already_mirrored}
      true -> :ok
    end
  end

  defp ensure_updatable_message(%Message{} = message) do
    cond do
      message.visibility != "public" -> {:skip, :not_public}
      message.federated -> {:skip, :remote_message}
      message.post_type == "message" -> {:skip, :not_timeline_post}
      is_nil(message.sender_id) -> {:skip, :missing_sender}
      not (is_binary(message.bluesky_uri) and message.bluesky_uri != "") -> {:skip, :not_mirrored}
      not is_nil(message.deleted_at) -> {:skip, :already_deleted}
      true -> :ok
    end
  end

  defp ensure_deletable_message(%Message{} = message) do
    cond do
      message.federated -> {:skip, :remote_message}
      is_nil(message.sender_id) -> {:skip, :missing_sender}
      not (is_binary(message.bluesky_uri) and message.bluesky_uri != "") -> {:skip, :not_mirrored}
      true -> :ok
    end
  end

  defp fetch_sender(nil) do
    {:skip, :missing_sender}
  end

  defp fetch_sender(sender_id) do
    case Repo.get(User, sender_id) do
      %User{} = user -> {:ok, user}
      _ -> {:skip, :sender_not_found}
    end
  end

  defp fetch_user(user_id) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, user}
      _ -> {:skip, :user_not_found}
    end
  end

  defp fetch_user(_) do
    {:skip, :user_not_found}
  end

  defp ensure_user_enabled(%User{bluesky_enabled: true}) do
    :ok
  end

  defp ensure_user_enabled(_) do
    {:skip, :user_not_enabled}
  end

  defp require_user_value(value, reason) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, reason}
    else
      {:ok, trimmed}
    end
  end

  defp require_user_value(_value, reason) do
    {:error, reason}
  end

  defp service_url_for(%User{bluesky_pds_url: user_pds_url}) do
    configured = Keyword.get(bluesky_config(), :service_url, "https://bsky.social")
    normalize_service_url(user_pds_url || configured)
  end

  defp normalize_service_url(url) when is_binary(url) do
    url = url |> String.trim() |> ensure_url_scheme() |> String.trim_trailing("/")

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :invalid_service_url}
    end
  end

  defp normalize_service_url(_) do
    {:error, :invalid_service_url}
  end

  defp ensure_url_scheme(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      "https://" <> url
    end
  end

  defp build_post_text(%Message{} = message) do
    decrypted = Message.decrypt_content(message)

    text =
      [cw_prefix(message.content_warning), title_prefix(message.title), decrypted.content]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n\n")
      |> String.trim()

    cond do
      text != "" ->
        {:ok, clamp_text(text)}

      is_binary(message.primary_url) and String.trim(message.primary_url) != "" ->
        {:ok, clamp_text(String.trim(message.primary_url))}

      is_list(message.media_urls) and message.media_urls != [] ->
        {:ok, ""}

      true ->
        {:skip, :empty_post}
    end
  end

  defp cw_prefix(nil) do
    nil
  end

  defp cw_prefix("") do
    nil
  end

  defp cw_prefix(value) do
    "[CW] " <> String.trim(value)
  end

  defp title_prefix(nil) do
    nil
  end

  defp title_prefix("") do
    nil
  end

  defp title_prefix(value) do
    String.trim(value)
  end

  defp clamp_text(text) do
    max_chars = max(1, Keyword.get(bluesky_config(), :max_chars, @default_max_chars))

    if String.length(text) <= max_chars do
      text
    else
      truncated =
        if max_chars <= 3 do
          String.slice(text, 0, max_chars)
        else
          String.slice(text, 0, max_chars - 3) <> "..."
        end

      String.trim(truncated)
    end
  end

  defp build_record(%Message{} = message, text, reply_payload, session) do
    with {:ok, facets} <- maybe_build_facets(text, session),
         {:ok, embed_payload} <- maybe_build_embed_payload(message, session) do
      record =
        %{
          "$type" => @post_collection,
          "text" => text,
          "createdAt" => format_created_at(message.inserted_at)
        }
        |> maybe_put_reply(reply_payload)
        |> maybe_put_facets(facets)
        |> maybe_put_embed(embed_payload)

      {:ok, record}
    end
  end

  defp maybe_put_reply(record, nil) do
    record
  end

  defp maybe_put_reply(record, reply) do
    Map.put(record, "reply", reply)
  end

  defp maybe_put_facets(record, []) do
    record
  end

  defp maybe_put_facets(record, nil) do
    record
  end

  defp maybe_put_facets(record, facets) do
    Map.put(record, "facets", facets)
  end

  defp maybe_put_embed(record, nil) do
    record
  end

  defp maybe_put_embed(record, embed) do
    Map.put(record, "embed", embed)
  end

  defp maybe_build_facets(text, _session) when not is_binary(text) do
    {:ok, []}
  end

  defp maybe_build_facets("", _session) do
    {:ok, []}
  end

  defp maybe_build_facets(text, session) do
    link_candidates = extract_link_candidates(text)
    link_ranges = Enum.map(link_candidates, &{&1.byte_start, &1.byte_end})
    mention_candidates = extract_mention_candidates(text, link_ranges)
    mention_ranges = Enum.map(mention_candidates, &{&1.byte_start, &1.byte_end})
    hashtag_candidates = extract_hashtag_candidates(text, link_ranges ++ mention_ranges)

    {mention_facets, _cache} =
      Enum.reduce(mention_candidates, {[], %{}}, fn candidate, {acc, cache} ->
        {did, next_cache} = resolve_mention_did_cached(candidate.handle, session, cache)

        if is_binary(did) and did != "" do
          facet = %{
            "index" => %{"byteStart" => candidate.byte_start, "byteEnd" => candidate.byte_end},
            "features" => [%{"$type" => @facet_mention_type, "did" => did}]
          }

          {[facet | acc], next_cache}
        else
          {acc, next_cache}
        end
      end)

    facets = link_facets(link_candidates) ++ mention_facets ++ hashtag_facets(hashtag_candidates)
    {:ok, facets |> Enum.sort_by(&get_in(&1, ["index", "byteStart"])) |> Enum.take(@max_facets)}
  end

  defp extract_link_candidates(text) do
    Regex.scan(~r/https?:\/\/[^\s<>()]+/u, text, return: :index)
    |> Enum.reduce([], fn
      [{byte_start, byte_len}], acc ->
        raw_url = binary_part(text, byte_start, byte_len)
        trimmed_url = trim_trailing_url_punctuation(raw_url)
        trimmed_len = byte_size(trimmed_url)

        cond do
          trimmed_url == "" ->
            acc

          not valid_absolute_http_url?(trimmed_url) ->
            acc

          true ->
            [
              %{byte_start: byte_start, byte_end: byte_start + trimmed_len, url: trimmed_url}
              | acc
            ]
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp trim_trailing_url_punctuation(url) when is_binary(url) do
    url
    |> String.trim_trailing(")")
    |> String.trim_trailing("]")
    |> String.trim_trailing("}")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> String.trim_trailing("!")
    |> String.trim_trailing("?")
    |> String.trim_trailing(";")
    |> String.trim_trailing(":")
  end

  defp trim_trailing_url_punctuation(_url) do
    ""
  end

  defp valid_absolute_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_absolute_http_url?(_url) do
    false
  end

  defp extract_mention_candidates(text, occupied_ranges) do
    Regex.scan(~r/@([A-Za-z0-9][A-Za-z0-9._-]{0,62})/u, text, return: :index, capture: :all)
    |> Enum.reduce([], fn
      [{byte_start, byte_len}, {handle_start, handle_len}], acc ->
        byte_end = byte_start + byte_len
        handle = binary_part(text, handle_start, handle_len)

        if mention_or_tag_boundary?(text, byte_start) and
             not overlaps_any?({byte_start, byte_end}, occupied_ranges) do
          [%{byte_start: byte_start, byte_end: byte_end, handle: handle} | acc]
        else
          acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp extract_hashtag_candidates(text, occupied_ranges) do
    Regex.scan(~r/#([[:alnum:]_]{1,64})/u, text, return: :index, capture: :all)
    |> Enum.reduce([], fn
      [{byte_start, byte_len}, {tag_start, tag_len}], acc ->
        byte_end = byte_start + byte_len
        tag = binary_part(text, tag_start, tag_len)

        if mention_or_tag_boundary?(text, byte_start) and
             not overlaps_any?({byte_start, byte_end}, occupied_ranges) do
          [%{byte_start: byte_start, byte_end: byte_end, tag: tag} | acc]
        else
          acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp mention_or_tag_boundary?(text, byte_start) do
    case preceding_character(text, byte_start) do
      nil -> true
      char -> not String.match?(char, ~r/[A-Za-z0-9_]/u)
    end
  end

  defp preceding_character(_text, byte_start) when byte_start <= 0 do
    nil
  end

  defp preceding_character(text, byte_start) when is_binary(text) and byte_start > 0 do
    text |> binary_part(0, byte_start) |> String.last()
  end

  defp overlaps_any?({start_a, end_a}, ranges) do
    Enum.any?(ranges, fn {start_b, end_b} -> start_a < end_b and end_a > start_b end)
  end

  defp link_facets(candidates) do
    Enum.map(candidates, fn candidate ->
      %{
        "index" => %{"byteStart" => candidate.byte_start, "byteEnd" => candidate.byte_end},
        "features" => [%{"$type" => @facet_link_type, "uri" => candidate.url}]
      }
    end)
  end

  defp hashtag_facets(candidates) do
    Enum.map(candidates, fn candidate ->
      %{
        "index" => %{"byteStart" => candidate.byte_start, "byteEnd" => candidate.byte_end},
        "features" => [%{"$type" => @facet_tag_type, "tag" => candidate.tag}]
      }
    end)
  end

  defp resolve_mention_did_cached(handle, session, cache) do
    key = String.downcase(handle || "")

    case Map.fetch(cache, key) do
      {:ok, did} ->
        {did, cache}

      :error ->
        did = resolve_mention_did(key, session)
        {did, Map.put(cache, key, did)}
    end
  end

  defp resolve_mention_did(handle, _session) when not is_binary(handle) do
    nil
  end

  defp resolve_mention_did("", _session) do
    nil
  end

  defp resolve_mention_did(handle, session) do
    local_user = Repo.get_by(User, handle: handle) || Repo.get_by(User, username: handle)

    cond do
      match?(%User{bluesky_did: did} when is_binary(did) and did != "", local_user) ->
        local_user.bluesky_did

      match?(%User{bluesky_identifier: "did:" <> _}, local_user) ->
        local_user.bluesky_identifier

      match?(%User{bluesky_identifier: identifier} when is_binary(identifier), local_user) ->
        case resolve_handle_to_did(session.service_url, local_user.bluesky_identifier) do
          {:ok, did} ->
            persist_user_did(local_user.id, did)
            did

          _ ->
            nil
        end

      String.contains?(handle, ".") ->
        case resolve_handle_to_did(session.service_url, handle) do
          {:ok, did} -> did
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp maybe_build_embed_payload(%Message{} = message, session) do
    with {:ok, media_embed} <- maybe_build_media_embed(message, session),
         {:ok, link_embed} <- maybe_build_link_embed(message),
         {:ok, quote_embed} <- maybe_build_quote_embed(message) do
      embed =
        case {quote_embed, media_embed || link_embed} do
          {nil, nil} -> nil
          {nil, media_or_link} -> media_or_link
          {quote, nil} -> quote
          {quote, media_or_link} -> build_record_with_media_embed(quote, media_or_link)
        end

      {:ok, embed}
    end
  end

  defp maybe_build_media_embed(%Message{media_urls: media_urls} = message, session)
       when is_list(media_urls) and media_urls != [] do
    state =
      media_urls
      |> Enum.with_index()
      |> Enum.reduce(%{images: [], video: nil, external: nil}, fn {media_source, index}, acc ->
        if media_kind(guess_media_type(media_source)) == :other do
          maybe_add_external_from_source(message, media_source, index, acc)
        else
          case fetch_media_binary(media_source) do
            {:ok, binary, content_type} ->
              case media_kind(content_type) do
                :image ->
                  maybe_add_image_blob(
                    message,
                    session,
                    media_source,
                    index,
                    binary,
                    content_type,
                    acc
                  )

                :video ->
                  maybe_add_video_blob(
                    message,
                    session,
                    media_source,
                    index,
                    binary,
                    content_type,
                    acc
                  )

                :other ->
                  maybe_add_external_from_source(message, media_source, index, acc)
              end

            {:skip, _reason} ->
              maybe_add_external_from_source(message, media_source, index, acc)

            {:error, reason} ->
              Logger.warning(
                "Bluesky media embed skipped for message #{message.id} at index #{index}: #{inspect(reason)}"
              )

              acc
          end
        end
      end)

    embed =
      cond do
        state.images != [] ->
          %{"$type" => @images_embed_type, "images" => Enum.reverse(state.images)}

        is_map(state.video) ->
          state.video

        is_map(state.external) ->
          state.external

        true ->
          nil
      end

    {:ok, embed}
  end

  defp maybe_build_media_embed(_message, _session) do
    {:ok, nil}
  end

  defp maybe_add_image_blob(
         %Message{} = message,
         %{service_url: service_url, access_jwt: access_jwt},
         media_source,
         index,
         binary,
         content_type,
         %{images: images} = acc
       ) do
    if length(images) >= @max_embed_images do
      acc
    else
      case upload_blob(service_url, access_jwt, binary, content_type) do
        {:ok, blob} ->
          image = %{"image" => blob, "alt" => media_alt_text(message, media_source, index)}
          %{acc | images: [image | images]}

        {:error, reason} ->
          Logger.warning(
            "Bluesky image upload failed for message #{message.id} at index #{index}: #{inspect(reason)}"
          )

          acc
      end
    end
  end

  defp maybe_add_video_blob(
         %Message{} = message,
         %{service_url: service_url, access_jwt: access_jwt},
         media_source,
         index,
         binary,
         content_type,
         %{video: video} = acc
       ) do
    if is_map(video) do
      acc
    else
      case upload_blob(service_url, access_jwt, binary, content_type) do
        {:ok, blob} ->
          %{
            acc
            | video: %{
                "$type" => @video_embed_type,
                "video" => blob,
                "alt" => media_alt_text(message, media_source, index)
              }
          }

        {:error, reason} ->
          Logger.warning(
            "Bluesky video upload failed for message #{message.id} at index #{index}: #{inspect(reason)}"
          )

          acc
      end
    end
  end

  defp maybe_add_external_from_source(
         %Message{} = message,
         media_source,
         index,
         %{external: external} = acc
       ) do
    if is_map(external) do
      acc
    else
      case external_uri_for_media_source(media_source) do
        {:ok, uri} -> %{acc | external: build_external_embed(uri, message, media_source, index)}
        _ -> acc
      end
    end
  end

  defp build_record_with_media_embed(record_embed, media_embed) do
    %{"$type" => @record_with_media_embed_type, "record" => record_embed, "media" => media_embed}
  end

  defp maybe_build_link_embed(%Message{primary_url: primary_url} = message)
       when is_binary(primary_url) do
    primary_url
    |> String.trim()
    |> normalize_external_uri()
    |> case do
      {:ok, uri} -> {:ok, build_external_embed(uri, message, uri, 0)}
      _ -> {:ok, nil}
    end
  end

  defp maybe_build_link_embed(_message) do
    {:ok, nil}
  end

  defp maybe_build_quote_embed(%Message{quoted_message_id: quoted_message_id})
       when is_integer(quoted_message_id) do
    case Messaging.get_message(quoted_message_id) do
      %Message{bluesky_uri: uri, bluesky_cid: cid}
      when is_binary(uri) and uri != "" and is_binary(cid) and cid != "" ->
        {:ok, %{"$type" => @record_embed_type, "record" => %{"uri" => uri, "cid" => cid}}}

      _ ->
        {:ok, nil}
    end
  end

  defp maybe_build_quote_embed(_message) do
    {:ok, nil}
  end

  defp build_external_embed(uri, message, media_source, index) do
    %{
      "$type" => @external_embed_type,
      "external" => %{
        "uri" => uri,
        "title" => external_title_for(message, media_source, index),
        "description" => external_description_for(message)
      }
    }
  end

  defp external_title_for(%Message{} = message, media_source, _index) do
    title =
      if is_binary(message.title) and String.trim(message.title) != "" do
        String.trim(message.title)
      else
        media_source |> to_string() |> source_display_name()
      end

    title |> String.slice(0, @max_external_title_chars) |> blank_to_default("Shared link")
  end

  defp external_description_for(%Message{} = message) do
    decrypted = Message.decrypt_content(message)

    [message.content_warning, decrypted.content]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> String.trim()
    |> String.slice(0, @max_external_description_chars)
    |> blank_to_default("Shared from Elektrine")
  end

  defp blank_to_default(value, default) when is_binary(value) do
    if String.trim(value) == "" do
      default
    else
      value
    end
  end

  defp blank_to_default(_value, default) do
    default
  end

  defp source_display_name(source) when is_binary(source) do
    with {:ok, normalized} <- normalize_external_uri(source),
         %URI{} = parsed <- URI.parse(normalized),
         path when is_binary(path) <- parsed.path do
      path
      |> Path.basename()
      |> case do
        "" -> normalized
        basename -> basename
      end
    else
      _ -> source |> String.split("/") |> List.last() |> to_string()
    end
  end

  defp source_display_name(source) do
    to_string(source)
  end

  defp external_uri_for_media_source(media_source) do
    cond do
      not is_binary(media_source) ->
        {:skip, :invalid_media_source}

      String.starts_with?(media_source, ["http://", "https://"]) ->
        normalize_external_uri(media_source)

      String.starts_with?(media_source, "/") ->
        normalize_external_uri(ActivityPub.instance_url() <> media_source)

      true ->
        media_source |> Uploads.attachment_url() |> normalize_external_uri()
    end
  rescue
    _ -> {:skip, :external_uri_unavailable}
  end

  defp normalize_external_uri(nil) do
    {:skip, :missing_external_uri}
  end

  defp normalize_external_uri("") do
    {:skip, :missing_external_uri}
  end

  defp normalize_external_uri(uri) when is_binary(uri) do
    uri = String.trim(uri)

    cond do
      uri == "" ->
        {:skip, :missing_external_uri}

      String.starts_with?(uri, "/") ->
        {:ok, ActivityPub.instance_url() <> uri}

      String.starts_with?(uri, ["http://", "https://"]) ->
        if valid_absolute_http_url?(uri) do
          {:ok, uri}
        else
          {:skip, :invalid_external_uri}
        end

      true ->
        candidate = "https://" <> uri

        if valid_absolute_http_url?(candidate) do
          {:ok, candidate}
        else
          {:skip, :invalid_external_uri}
        end
    end
  end

  defp normalize_external_uri(_) do
    {:skip, :invalid_external_uri}
  end

  defp fetch_media_binary(source) when not is_binary(source) do
    {:skip, :invalid_media_source}
  end

  defp fetch_media_binary("") do
    {:skip, :empty_media_source}
  end

  defp fetch_media_binary(source) do
    source = String.trim(source)

    cond do
      source == "" ->
        {:skip, :empty_media_source}

      String.starts_with?(source, ["http://", "https://"]) ->
        fetch_media_binary_from_url(source, guess_media_type(source))

      true ->
        case local_media_path_for(source) do
          {:ok, path, fallback_content_type} ->
            read_media_from_file(path, fallback_content_type)

          :error ->
            source
            |> remote_media_url_for()
            |> fetch_media_binary_from_url(guess_media_type(source))
        end
    end
  end

  defp remote_media_url_for(source) do
    case Uploads.attachment_url(source) do
      "/uploads/" <> _rest = local_source ->
        case local_media_path_for(local_source) do
          {:ok, path, fallback_content_type} -> {:file, path, fallback_content_type}
          :error -> {:skip, :unsupported_media_source}
        end

      url when is_binary(url) ->
        if String.starts_with?(url, ["http://", "https://"]) do
          {:ok, url}
        else
          {:skip, :unsupported_media_source}
        end

      _ ->
        {:skip, :unsupported_media_source}
    end
  rescue
    _ -> {:skip, :unsupported_media_source}
  end

  defp fetch_media_binary_from_url({:file, path, fallback_content_type}, _fallback_guess) do
    read_media_from_file(path, fallback_content_type)
  end

  defp fetch_media_binary_from_url({:ok, url}, fallback_guess) do
    fetch_media_binary_from_url(url, fallback_guess)
  end

  defp fetch_media_binary_from_url({:skip, reason}, _fallback_guess) do
    {:skip, reason}
  end

  defp fetch_media_binary_from_url(url, fallback_guess) when is_binary(url) and url != "" do
    headers = [{"accept", "*/*"}]

    with {:ok, %Finch.Response{} = response} <- request_raw(:get, url, headers, ""),
         :ok <- require_success_status(response.status, :media_fetch_failed) do
      content_type =
        response.headers |> response_content_type() |> maybe_fallback_content_type(fallback_guess)

      {:ok, response.body, content_type}
    end
  end

  defp fetch_media_binary_from_url(_url, _fallback_guess) do
    {:skip, :invalid_media_source}
  end

  defp read_media_from_file(path, fallback_content_type) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary, fallback_content_type}
      {:error, reason} -> {:error, {:media_read_failed, reason}}
    end
  end

  defp local_media_path_for("/uploads/" <> rest) do
    uploads_dir =
      Application.get_env(:elektrine, :uploads, [])
      |> Keyword.get(:uploads_dir, "priv/static/uploads")

    path = Path.join(uploads_dir, rest)
    {:ok, path, guess_media_type(rest)}
  end

  defp local_media_path_for(source) do
    adapter = Application.get_env(:elektrine, :uploads, []) |> Keyword.get(:adapter, :local)

    if adapter == :local and local_media_key?(source) do
      uploads_dir =
        Application.get_env(:elektrine, :uploads, [])
        |> Keyword.get(:uploads_dir, "priv/static/uploads")

      normalized = source |> String.trim_leading("/") |> String.trim_leading("uploads/")
      {:ok, Path.join(uploads_dir, normalized), guess_media_type(source)}
    else
      :error
    end
  end

  defp local_media_key?(source) when is_binary(source) do
    Enum.any?(@local_media_prefixes, &String.starts_with?(source, &1))
  end

  defp local_media_key?(_source) do
    false
  end

  defp media_alt_text(%Message{media_metadata: media_metadata}, media_source, index) do
    alt_texts =
      case media_metadata do
        %{"alt_texts" => map} when is_map(map) -> map
        %{alt_texts: map} when is_map(map) -> map
        _ -> %{}
      end

    alt_value =
      Map.get(alt_texts, to_string(index)) || Map.get(alt_texts, index) ||
        Map.get(alt_texts, media_source)

    normalize_alt_text(alt_value)
  end

  defp normalize_alt_text(value) when is_binary(value) do
    value |> String.trim() |> String.slice(0, @max_alt_text_chars)
  end

  defp normalize_alt_text(_value) do
    ""
  end

  defp response_content_type(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type" do
          normalize_content_type(value)
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp response_content_type(_headers) do
    nil
  end

  defp maybe_fallback_content_type(nil, fallback) do
    fallback || "application/octet-stream"
  end

  defp maybe_fallback_content_type(content_type, _fallback) do
    content_type
  end

  defp normalize_content_type(value) when is_binary(value) do
    value
    |> String.split(";")
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_content_type(_value) do
    "application/octet-stream"
  end

  defp media_kind("image/" <> _rest) do
    :image
  end

  defp media_kind("video/" <> _rest) do
    :video
  end

  defp media_kind(_content_type) do
    :other
  end

  defp guess_media_type(value) when is_binary(value) do
    normalized = value |> String.downcase() |> String.split("?") |> List.first()

    cond do
      String.ends_with?(normalized, [".jpg", ".jpeg"]) -> "image/jpeg"
      String.ends_with?(normalized, ".png") -> "image/png"
      String.ends_with?(normalized, ".gif") -> "image/gif"
      String.ends_with?(normalized, ".webp") -> "image/webp"
      String.ends_with?(normalized, ".svg") -> "image/svg+xml"
      String.ends_with?(normalized, ".bmp") -> "image/bmp"
      String.ends_with?(normalized, ".ico") -> "image/x-icon"
      String.ends_with?(normalized, ".mp4") -> "video/mp4"
      String.ends_with?(normalized, ".webm") -> "video/webm"
      String.ends_with?(normalized, ".ogv") -> "video/ogg"
      String.ends_with?(normalized, ".mov") -> "video/quicktime"
      String.ends_with?(normalized, ".mp3") -> "audio/mpeg"
      String.ends_with?(normalized, ".ogg") -> "audio/ogg"
      String.ends_with?(normalized, ".wav") -> "audio/wav"
      String.ends_with?(normalized, ".m4a") -> "audio/mp4"
      String.ends_with?(normalized, ".aac") -> "audio/aac"
      String.ends_with?(normalized, ".flac") -> "audio/flac"
      String.ends_with?(normalized, ".pdf") -> "application/pdf"
      true -> "application/octet-stream"
    end
  end

  defp guess_media_type(_value) do
    "application/octet-stream"
  end

  defp maybe_build_reply_payload(nil) do
    {:ok, nil}
  end

  defp maybe_build_reply_payload(reply_to_id) do
    case Messaging.get_message(reply_to_id) do
      %Message{bluesky_uri: uri, bluesky_cid: cid} = parent
      when is_binary(uri) and uri != "" and is_binary(cid) and cid != "" ->
        parent_ref = %{"uri" => uri, "cid" => cid}
        root_ref = find_root_reference(parent, parent_ref)
        {:ok, %{"root" => root_ref, "parent" => parent_ref}}

      _ ->
        {:skip, :reply_parent_not_mirrored}
    end
  end

  defp find_root_reference(_message, current_ref, depth) when depth >= @max_reply_depth do
    current_ref
  end

  defp find_root_reference(%Message{reply_to_id: nil}, current_ref, _depth) do
    current_ref
  end

  defp find_root_reference(%Message{reply_to_id: reply_to_id}, current_ref, depth) do
    case Messaging.get_message(reply_to_id) do
      %Message{bluesky_uri: uri, bluesky_cid: cid} = parent
      when is_binary(uri) and uri != "" and is_binary(cid) and cid != "" ->
        next_ref = %{"uri" => uri, "cid" => cid}
        find_root_reference(parent, next_ref, depth + 1)

      _ ->
        current_ref
    end
  end

  defp find_root_reference(message, current_ref) do
    find_root_reference(message, current_ref, 0)
  end

  defp create_session(service_url, identifier, password) do
    url = service_url <> "/xrpc/com.atproto.server.createSession"
    payload = %{identifier: identifier, password: password}

    with {:ok, %Finch.Response{} = response} <- request_json(:post, url, payload),
         :ok <- require_success_status(response.status, :create_session_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, access_jwt} <- map_fetch_string(body, "accessJwt", :missing_access_jwt),
         {:ok, did} <- map_fetch_string(body, "did", :missing_did) do
      {:ok, %{access_jwt: access_jwt, did: did}}
    end
  end

  defp create_record(service_url, access_jwt, did, record, collection \\ @post_collection) do
    url = service_url <> "/xrpc/com.atproto.repo.createRecord"
    payload = %{repo: did, collection: collection, record: record}
    headers = [{"authorization", "Bearer " <> access_jwt}]

    with {:ok, %Finch.Response{} = response} <- request_json(:post, url, payload, headers),
         :ok <- require_success_status(response.status, :create_record_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, uri} <- map_fetch_string(body, "uri", :missing_uri),
         {:ok, cid} <- map_fetch_string(body, "cid", :missing_cid) do
      {:ok, %{uri: uri, cid: cid}}
    end
  end

  defp upload_blob(service_url, access_jwt, binary, content_type) do
    url = service_url <> "/xrpc/com.atproto.repo.uploadBlob"

    headers = [
      {"authorization", "Bearer " <> access_jwt},
      {"content-type", content_type || "application/octet-stream"},
      {"accept", "application/json"}
    ]

    with {:ok, %Finch.Response{} = response} <- request_raw(:post, url, headers, binary),
         :ok <- require_success_status(response.status, :upload_blob_failed),
         {:ok, body} <- decode_json_body(response.body) do
      map_fetch_map(body, "blob", :missing_blob)
    end
  end

  defp put_record(service_url, access_jwt, repo, collection, rkey, record) do
    url = service_url <> "/xrpc/com.atproto.repo.putRecord"
    payload = %{repo: repo, collection: collection, rkey: rkey, record: record}
    headers = [{"authorization", "Bearer " <> access_jwt}]

    with {:ok, %Finch.Response{} = response} <- request_json(:post, url, payload, headers),
         :ok <- require_success_status(response.status, :put_record_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, uri} <- map_fetch_string(body, "uri", :missing_uri),
         {:ok, cid} <- map_fetch_string(body, "cid", :missing_cid) do
      {:ok, %{uri: uri, cid: cid}}
    end
  end

  defp delete_record(service_url, access_jwt, repo, collection, rkey) do
    url = service_url <> "/xrpc/com.atproto.repo.deleteRecord"
    payload = %{repo: repo, collection: collection, rkey: rkey}
    headers = [{"authorization", "Bearer " <> access_jwt}]

    with {:ok, %Finch.Response{} = response} <- request_json(:post, url, payload, headers) do
      require_success_status(response.status, :delete_record_failed)
    end
  end

  defp list_records(service_url, access_jwt, repo, collection, cursor) do
    params =
      %{
        "repo" => repo,
        "collection" => collection,
        "limit" => Integer.to_string(@default_record_list_limit)
      }
      |> maybe_put_cursor_param(cursor)

    url = service_url <> "/xrpc/com.atproto.repo.listRecords?" <> URI.encode_query(params)
    headers = [{"accept", "application/json"}, {"authorization", "Bearer " <> access_jwt}]

    with {:ok, %Finch.Response{} = response} <- request_raw(:get, url, headers, ""),
         :ok <- require_success_status(response.status, :list_records_failed),
         {:ok, body} <- decode_json_body(response.body),
         {:ok, records} <- map_fetch_list(body, "records", :missing_records) do
      {:ok, %{records: records, cursor: body["cursor"]}}
    end
  end

  defp maybe_put_cursor_param(params, cursor) when is_binary(cursor) and cursor != "" do
    Map.put(params, "cursor", cursor)
  end

  defp maybe_put_cursor_param(params, _cursor) do
    params
  end

  defp request_json(method, url, payload, extra_headers \\ []) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"} | extra_headers
    ]

    body = Jason.encode!(payload)
    request_raw(method, url, headers, body)
  end

  defp request_raw(method, url, headers, body) do
    timeout_ms = Keyword.get(bluesky_config(), :timeout_ms, @default_timeout_ms)

    case http_client().request(method, url, headers, body, receive_timeout: timeout_ms) do
      {:ok, %Finch.Response{} = response} -> {:ok, response}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp require_success_status(status, _reason) when status in 200..299 do
    :ok
  end

  defp require_success_status(status, reason) do
    {:error, {reason, status}}
  end

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json_body(_) do
    {:error, :invalid_json}
  end

  defp map_fetch_string(map, key, reason) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reason}
    end
  end

  defp map_fetch_string(_map, _key, reason) do
    {:error, reason}
  end

  defp map_fetch_map(map, key, reason) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, reason}
    end
  end

  defp map_fetch_map(_map, _key, reason) do
    {:error, reason}
  end

  defp map_fetch_list(map, key, reason) when is_map(map) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, reason}
    end
  end

  defp map_fetch_list(_map, _key, reason) do
    {:error, reason}
  end

  defp fetch_mirrored_subject_message(message_id) when is_integer(message_id) do
    case Repo.get(Message, message_id) do
      %Message{bluesky_uri: uri, bluesky_cid: cid} = message
      when is_binary(uri) and uri != "" and is_binary(cid) and cid != "" ->
        {:ok, message}

      %Message{} ->
        {:skip, :message_not_mirrored}

      nil ->
        {:skip, :message_not_found}
    end
  end

  defp fetch_mirrored_subject_message(_) do
    {:skip, :message_not_found}
  end

  defp parse_at_uri("at://" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [repo, collection, rkey] when repo != "" and collection != "" and rkey != "" ->
        {:ok, %{repo: repo, collection: collection, rkey: rkey, uri: "at://" <> rest}}

      _ ->
        {:error, :invalid_at_uri}
    end
  end

  defp parse_at_uri(_value) do
    {:error, :invalid_at_uri}
  end

  defp ensure_collection(collection, expected) when collection == expected do
    :ok
  end

  defp ensure_collection(_collection, _expected) do
    {:error, :unexpected_collection}
  end

  defp maybe_create_subject_record(_session, _collection, existing_uri, _record)
       when is_binary(existing_uri) and existing_uri != "" do
    {:ok, %{uri: existing_uri, cid: nil}}
  end

  defp maybe_create_subject_record(session, collection, nil, record) do
    create_record(session.service_url, session.access_jwt, session.did, record, collection)
  end

  defp find_subject_record_uri(session, collection, subject_uri) do
    find_record_uri(session, collection, fn record ->
      get_in(record, ["value", "subject", "uri"]) == subject_uri
    end)
  end

  defp find_follow_record_uri(session, collection, target_did) do
    find_record_uri(session, collection, fn record ->
      get_in(record, ["value", "subject"]) == target_did
    end)
  end

  defp find_record_uri(session, collection, matcher, cursor \\ nil, depth \\ 0)

  defp find_record_uri(_session, _collection, _matcher, _cursor, depth) when depth >= 10 do
    {:ok, nil}
  end

  defp find_record_uri(session, collection, matcher, cursor, depth) do
    with {:ok, response} <-
           list_records(session.service_url, session.access_jwt, session.did, collection, cursor) do
      case Enum.find(response.records, matcher) do
        %{"uri" => uri} when is_binary(uri) and uri != "" ->
          {:ok, uri}

        _ ->
          case response.cursor do
            next_cursor when is_binary(next_cursor) and next_cursor != "" ->
              find_record_uri(session, collection, matcher, next_cursor, depth + 1)

            _ ->
              {:ok, nil}
          end
      end
    end
  end

  defp maybe_delete_record_by_uri(_session, _collection, nil) do
    :ok
  end

  defp maybe_delete_record_by_uri(session, collection, uri) when is_binary(uri) do
    with {:ok, parsed} <- parse_at_uri(uri),
         :ok <- ensure_collection(parsed.collection, collection) do
      delete_record(
        session.service_url,
        session.access_jwt,
        parsed.repo,
        parsed.collection,
        parsed.rkey
      )
    end
  end

  defp maybe_delete_record_by_uri(_session, _collection, _uri) do
    {:error, :invalid_record_uri}
  end

  defp resolve_follow_target_did(%User{} = followed, session) do
    cond do
      is_binary(followed.bluesky_did) and followed.bluesky_did != "" ->
        {:ok, followed.bluesky_did}

      is_binary(followed.bluesky_identifier) and
          String.starts_with?(followed.bluesky_identifier, "did:") ->
        {:ok, followed.bluesky_identifier}

      is_binary(followed.bluesky_identifier) and followed.bluesky_identifier != "" ->
        case resolve_handle_to_did(session.service_url, followed.bluesky_identifier) do
          {:ok, did} ->
            persist_user_did(followed.id, did)
            {:ok, did}

          {:error, _reason} ->
            {:skip, :target_did_unresolvable}
        end

      true ->
        {:skip, :target_missing_bluesky_identity}
    end
  end

  defp resolve_handle_to_did(service_url, handle) do
    normalized = String.trim(handle || "")

    cond do
      normalized == "" ->
        {:error, :missing_handle}

      String.starts_with?(normalized, "did:") ->
        {:ok, normalized}

      true ->
        url =
          service_url <>
            "/xrpc/com.atproto.identity.resolveHandle?handle=" <> URI.encode_www_form(normalized)

        headers = [{"accept", "application/json"}]

        with {:ok, %Finch.Response{} = response} <- request_raw(:get, url, headers, ""),
             :ok <- require_success_status(response.status, :resolve_handle_failed),
             {:ok, body} <- decode_json_body(response.body) do
          map_fetch_string(body, "did", :missing_did)
        end
    end
  end

  defp persist_message_mapping(message_id, %{uri: uri, cid: cid}) do
    from(m in Message, where: m.id == ^message_id and is_nil(m.bluesky_uri))
    |> Repo.update_all(set: [bluesky_uri: uri, bluesky_cid: cid])

    :ok
  end

  defp persist_message_mapping_update(message_id, %{uri: uri, cid: cid}) do
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(set: [bluesky_uri: uri, bluesky_cid: cid])

    :ok
  end

  defp persist_user_did(user_id, did) when is_integer(user_id) and is_binary(did) and did != "" do
    from(u in User, where: u.id == ^user_id) |> Repo.update_all(set: [bluesky_did: did])
    :ok
  end

  defp persist_user_did(_user_id, _did) do
    :ok
  end

  defp format_created_at(nil) do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_created_at(%DateTime{} = datetime) do
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_created_at(datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp bluesky_config do
    Application.get_env(:elektrine, :bluesky, [])
  end

  defp http_client do
    Keyword.get(bluesky_config(), :http_client, Elektrine.Bluesky.FinchClient)
  end
end
