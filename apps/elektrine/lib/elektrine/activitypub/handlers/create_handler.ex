defmodule Elektrine.ActivityPub.Handlers.CreateHandler do
  @moduledoc """
  Handles Create ActivityPub activities for Notes, Pages, Articles, and Questions.
  """

  require Logger

  import Ecto.Query

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.ActivityPub.Visibility
  alias Elektrine.Async
  alias Elektrine.Emojis
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias Elektrine.Social.Poll

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
  Handles an incoming Create activity.
  """
  def handle(%{"object" => object} = activity, actor_uri, _target_user) when is_map(object) do
    object = inherit_wrapper_fields(activity, object)
    activity_id = activity["id"] || object["id"]
    opts = ingestion_opts(activity)

    case validate_object_author(object, actor_uri) do
      :ok ->
        case object["type"] do
          "Note" -> create_note(object, actor_uri, opts)
          "Page" -> create_note(object, actor_uri, opts)
          "Article" -> create_note(object, actor_uri, opts)
          "Question" -> create_question(object, actor_uri, opts)
          # Akkoma/Pleroma explicitly sends Answer type for poll votes
          "Answer" -> handle_incoming_poll_vote(object, actor_uri, activity_id: activity_id)
          _ -> {:ok, :unhandled}
        end

      {:error, :actor_mismatch} ->
        Logger.warning(
          "Rejecting Create #{inspect(activity_id)}: object attributedTo does not match verified actor #{actor_uri}"
        )

        {:ok, :unauthorized}
    end
  end

  def handle(%{"object" => object_uri} = activity, actor_uri, target_user)
      when is_binary(object_uri) do
    activity_id = activity["id"] || object_uri

    case ActivityPub.Fetcher.fetch_object(object_uri) do
      {:ok, object} when is_map(object) ->
        activity
        |> Map.put("object", Map.put_new(object, "attributedTo", actor_uri))
        |> handle(actor_uri, target_user)

      {:ok, _object} ->
        Logger.warning(
          "Rejecting Create #{inspect(activity_id)}: referenced object #{inspect(object_uri)} was not an object map"
        )

        {:error, :fetch_failed}

      {:error, reason} ->
        Logger.warning(
          "Rejecting Create #{inspect(activity_id)}: failed to fetch referenced object #{inspect(object_uri)} (#{inspect(reason)})"
        )

        {:error, :create_object_fetch_failed}
    end
  end

  @doc """
  Creates a note from an ActivityPub object.
  Public API for use by other handlers (e.g., AnnounceHandler).
  """
  def create_note(object, actor_uri) do
    create_note(object, actor_uri, [])
  end

  @doc """
  Creates a note from an ActivityPub object with extra ingestion options.
  Supported opts:
  - `:fallback_community_uri` - fallback Group/community URI when object fields are incomplete
  """
  def create_note(object, actor_uri, opts) when is_list(opts) do
    with :ok <- validate_object_author(object, actor_uri) do
      if poll_vote?(object) do
        handle_incoming_poll_vote(object, actor_uri, opts)
      else
        create_regular_note(object, actor_uri, opts)
      end
    end
  end

  @doc """
  Validates that an object's attributedTo matches the verified actor.
  """
  def validate_object_author(object, actor_uri) when is_map(object) do
    validate_create_author(object, actor_uri)
  end

  def validate_object_author(_object, _actor_uri), do: {:error, :actor_mismatch}

  @doc """
  Creates a Question (poll) from an ActivityPub object.
  """
  def create_question(object, actor_uri, opts \\ []) do
    if deleted_object_recorded?(object, actor_uri) do
      {:ok, :ignored_deleted_object}
    else
      with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
        payload = build_federated_question_payload(object, actor_uri, opts)
        attrs = Map.put(payload.attrs, :remote_actor_id, remote_actor.id)

        %URI{host: instance_domain} = URI.parse(actor_uri)
        Async.start(fn -> Emojis.process_activitypub_tags(object["tag"], instance_domain) end)

        if attrs.visibility in ["public", "unlisted"] do
          case Messaging.create_federated_message(Map.put(attrs, :federated, true)) do
            {:ok, message} ->
              if payload.options != [] do
                upsert_federated_poll(message.id, object, payload.options)
              end

              if payload.hashtags != [] do
                Async.run(fn -> sync_message_hashtags(message.id, payload.hashtags) end)
              end

              broadcast_created_message(message, opts, [
                :remote_actor,
                :sender,
                :conversation,
                :link_preview,
                :hashtags,
                poll: [options: []]
              ])

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
  end

  @doc false
  def build_federated_message_payload(object, actor_uri, opts \\ []) when is_map(object) do
    object = maybe_enrich_sparse_object(object)
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
          visibility: determine_visibility(object),
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
          sensitive: object["sensitive"] || false,
          content_warning: object["summary"]
        }
        |> Map.merge(federated_context_attrs(opts))
        |> Map.merge(Helpers.extract_vote_totals(object)),
      hashtags: hashtags,
      mentioned_local_users: extract_local_mentions(object)
    }
  end

  @doc false
  def build_federated_question_payload(object, actor_uri, opts \\ []) when is_map(object) do
    object = maybe_enrich_sparse_object(object)
    content = strip_html(object["content"] || "", object["tag"])
    question = extract_poll_question_text(object)
    hashtags = extract_hashtags(object, hashtag_source_content(content, question))
    {media_urls, alt_texts} = extract_media_with_alt_text(object)
    options = extract_poll_options(object)

    %{
      attrs:
        %{
          content: content,
          visibility: determine_visibility(object),
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

  @doc false
  def sync_message_hashtags(message_id, hashtag_names)
      when is_integer(message_id) and is_list(hashtag_names) do
    normalized_names =
      hashtag_names
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    existing_hashtags =
      from(
        ph in "post_hashtags",
        join: h in "hashtags",
        on: h.id == ph.hashtag_id,
        where: ph.message_id == ^message_id,
        select: %{id: h.id, normalized_name: h.normalized_name}
      )
      |> Elektrine.Repo.all()

    existing_names = MapSet.new(existing_hashtags, & &1.normalized_name)

    hashtags =
      normalized_names
      |> Enum.map(&Social.get_or_create_hashtag/1)
      |> Enum.filter(&(&1 != nil))
      |> Enum.uniq_by(& &1.id)

    new_names = MapSet.new(hashtags, & &1.normalized_name)

    from(ph in "post_hashtags", where: ph.message_id == ^message_id)
    |> Elektrine.Repo.delete_all()

    removed_hashtags =
      Enum.reject(existing_hashtags, fn hashtag ->
        MapSet.member?(new_names, hashtag.normalized_name)
      end)

    added_hashtags =
      Enum.reject(hashtags, fn hashtag ->
        MapSet.member?(existing_names, hashtag.normalized_name)
      end)

    if hashtags != [] do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      associations =
        Enum.map(hashtags, fn hashtag ->
          %{message_id: message_id, hashtag_id: hashtag.id, inserted_at: now}
        end)

      Elektrine.Repo.insert_all("post_hashtags", associations, on_conflict: :nothing)
    end

    Enum.each(removed_hashtags, fn hashtag -> Social.decrement_hashtag_usage(hashtag.id) end)
    Enum.each(added_hashtags, fn hashtag -> Social.increment_hashtag_usage(hashtag.id) end)

    :ok
  end

  def sync_message_hashtags(_message_id, _hashtag_names), do: :ok

  @doc false
  def upsert_federated_poll(message_id, object) when is_integer(message_id) and is_map(object) do
    upsert_federated_poll(message_id, object, extract_poll_options(object))
  end

  def upsert_federated_poll(_message_id, _object), do: {:error, :invalid_poll}

  @doc false
  def upsert_federated_poll(message_id, object, options)
      when is_integer(message_id) and is_map(object) and is_list(options) do
    do_upsert_federated_poll(message_id, object, options)
  end

  def upsert_federated_poll(_message_id, _object, _options), do: {:error, :invalid_poll}

  # Private functions

  defp poll_vote?(object) do
    has_name = Elektrine.Strings.present?(object["name"])
    has_reply_to = object["inReplyTo"] != nil
    content = object["content"] || ""
    has_minimal_content = String.length(strip_html(content, object["tag"])) < 5

    has_name && has_reply_to && has_minimal_content
  end

  defp handle_incoming_poll_vote(object, actor_uri, opts) do
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
        vote_id = Keyword.get(opts, :activity_id) || object["id"]

        record_remote_poll_vote(poll, message, option_name, actor_uri, vote_id)
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

  defp record_remote_poll_vote(poll, message, option_name, actor_uri, vote_id) do
    option_key =
      option_name
      |> to_string()
      |> String.trim()
      |> String.downcase()

    dedupe_vote_id =
      case vote_id do
        value when is_binary(value) and value != "" ->
          "poll-vote:#{value}"

        _ ->
          "poll-vote:#{actor_uri}:#{poll.id}:#{option_key}"
      end

    case persist_poll_vote_receipt(dedupe_vote_id, poll, message, actor_uri) do
      {:ok, :already_recorded} ->
        {:ok, :already_voted}

      {:ok, :recorded} ->
        Elektrine.Repo.transaction(fn ->
          locked_poll =
            from(p in Poll, where: p.id == ^poll.id, lock: "FOR UPDATE")
            |> Elektrine.Repo.one!()
            |> Elektrine.Repo.preload(:options)

          if Poll.has_voted?(locked_poll, actor_uri) do
            :already_voted
          else
            matching_option =
              Enum.find(locked_poll.options, fn opt ->
                String.downcase(String.trim(opt.option_text)) == option_key
              end)

            if matching_option do
              Elektrine.Repo.update_all(
                from(o in Elektrine.Social.PollOption, where: o.id == ^matching_option.id),
                inc: [vote_count: 1]
              )

              Elektrine.Repo.update_all(
                from(p in Poll, where: p.id == ^locked_poll.id),
                inc: [total_votes: 1]
              )

              case Poll.record_voter(locked_poll, actor_uri) do
                {:ok, _updated_poll} -> :poll_vote_recorded
                {:error, reason} -> Elektrine.Repo.rollback(reason)
              end
            else
              :option_not_found
            end
          end
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_poll_vote_receipt(vote_id, poll, message, actor_uri) do
    object_id =
      case message.activitypub_id do
        value when is_binary(value) and value != "" -> value
        _ -> Integer.to_string(poll.message_id)
      end

    case ActivityPub.create_activity(%{
           activity_id: vote_id,
           activity_type: "PollVote",
           actor_uri: actor_uri,
           object_id: object_id,
           data: %{
             "type" => "PollVote",
             "id" => vote_id,
             "actor" => actor_uri
           },
           local: false,
           processed: true,
           internal_message_id: poll.message_id
         }) do
      {:ok, _record} ->
        {:ok, :recorded}

      {:error, %Ecto.Changeset{errors: [activity_id: {"has already been taken", _}]}} ->
        {:ok, :already_recorded}

      {:error, reason} ->
        Logger.warning("Failed to persist poll vote receipt: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_regular_note(object, actor_uri, opts) do
    object = maybe_enrich_sparse_object(object)

    if deleted_object_recorded?(object, actor_uri) do
      {:ok, :ignored_deleted_object}
    else
      with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
        content = strip_html(object["content"] || "", object["tag"])
        title = normalize_object_title(object["name"])
        hashtags = extract_hashtags(object, content)
        mentioned_local_users = extract_local_mentions(object)

        %URI{host: instance_domain} = URI.parse(actor_uri)
        Async.start(fn -> Emojis.process_activitypub_tags(object["tag"], instance_domain) end)

        reply_to_id = get_reply_to_message_id(object["inReplyTo"])
        quoted_message_id = get_quoted_message_id(object)
        visibility = determine_visibility(object)

        if visibility in ["public", "unlisted"] do
          {media_urls, alt_texts} = extract_media_with_alt_text(object)

          result =
            Messaging.create_federated_message(
              %{
                content: content,
                title: title,
                visibility: visibility,
                activitypub_id: object["id"],
                activitypub_url: object["url"] || object["id"],
                federated: true,
                remote_actor_id: remote_actor.id,
                reply_to_id: reply_to_id,
                quoted_message_id: quoted_message_id,
                media_urls: media_urls,
                media_metadata:
                  build_metadata_with_engagement(
                    alt_texts,
                    object,
                    Keyword.put_new(opts, :author_uri, actor_uri)
                  ),
                inserted_at: Helpers.parse_published_date(object["published"]),
                extracted_hashtags: hashtags,
                like_count: Helpers.extract_interaction_count(object, "likes"),
                reply_count: Helpers.extract_interaction_count(object, "replies"),
                share_count: Helpers.extract_interaction_count(object, "shares"),
                sensitive: object["sensitive"] || false,
                content_warning: object["summary"]
              }
              |> Map.merge(federated_context_attrs(opts))
              |> Map.merge(Helpers.extract_vote_totals(object))
            )

          case result do
            {:ok, message} ->
              handle_post_create_tasks(
                message,
                remote_actor,
                hashtags,
                reply_to_id,
                mentioned_local_users,
                opts
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
  end

  defp handle_post_create_tasks(
         message,
         remote_actor,
         hashtags,
         reply_to_id,
         mentioned_local_users,
         opts
       ) do
    # Link hashtags
    if hashtags != [] do
      Async.run(fn -> link_hashtags_to_message(message.id, hashtags) end)
    end

    # Generate link preview
    Async.start(fn -> generate_link_preview_for_message(message) end)

    # Notify reply and increment parent's reply count
    if reply_to_id do
      # Increment reply count on parent (like Akkoma does)
      Elektrine.ActivityPub.SideEffects.increment_reply_count(reply_to_id)

      Async.run(fn ->
        Elektrine.Notifications.FederationNotifications.notify_remote_reply(
          message.id,
          remote_actor.id
        )
      end)
    else
      # If this is a reply but we don't have the parent locally yet, store the parent
      # so thread previews and conversation pages can render real ancestor content.
      Async.start(fn -> maybe_store_missing_reply_parent(message, remote_actor) end)
    end

    # Notify mentions
    if mentioned_local_users != [] do
      Async.run(fn ->
        notify_mentioned_users(mentioned_local_users, message.id, remote_actor.id)
      end)
    end

    # Broadcast to timelines or the addressed local community.
    broadcast_created_message(message, opts, [
      :remote_actor,
      :sender,
      :conversation,
      :link_preview,
      :hashtags
    ])
  end

  defp ingestion_opts(activity) when is_map(activity) do
    []
    |> maybe_put_opt(:conversation_id, activity["_elektrine_target_community_id"])
    |> maybe_put_opt(:fallback_community_uri, activity["_elektrine_target_community_uri"])
  end

  defp ingestion_opts(_), do: []

  defp maybe_put_opt(opts, key, value) when is_integer(value), do: Keyword.put(opts, key, value)

  defp maybe_put_opt(opts, key, value) when is_binary(value) and value != "",
    do: Keyword.put(opts, key, value)

  defp maybe_put_opt(opts, _key, _value), do: opts

  defp federated_context_attrs(opts) do
    case Keyword.get(opts, :conversation_id) do
      conversation_id when is_integer(conversation_id) -> %{conversation_id: conversation_id}
      _ -> %{}
    end
  end

  defp broadcast_created_message(message, opts, preloads) do
    reloaded_message = Elektrine.Repo.preload(message, preloads, force: true)

    case Keyword.get(opts, :conversation_id) do
      conversation_id when is_integer(conversation_id) ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{conversation_id}",
          {:new_message, reloaded_message}
        )

        if is_nil(reloaded_message.reply_to_id) do
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "discussion:#{conversation_id}",
            {:new_message, reloaded_message}
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "discussions:all",
            {:new_discussion_post, reloaded_message}
          )
        end

      _ ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "timeline:public",
          {:new_public_post, reloaded_message}
        )
    end
  end

  defp maybe_store_missing_reply_parent(message, remote_actor) do
    metadata = Map.get(message, :media_metadata) || %{}

    in_reply_to_ref =
      metadata["inReplyTo"] ||
        metadata[:inReplyTo] ||
        metadata["in_reply_to"] ||
        metadata[:in_reply_to]

    normalized_ref = normalize_uri(in_reply_to_ref)

    cond do
      !is_binary(normalized_ref) or normalized_ref == "" ->
        :ok

      message.reply_to_id ->
        :ok

      Messaging.get_message_by_activitypub_ref(normalized_ref) ->
        :ok

      true ->
        case Helpers.get_or_store_remote_post(normalized_ref, remote_actor && remote_actor.uri) do
          {:ok, parent_message} when is_map(parent_message) ->
            maybe_link_orphan_reply_to_parent(message, parent_message)

          _ ->
            :ok
        end

        :ok
    end
  end

  defp maybe_link_orphan_reply_to_parent(message, parent_message)
       when is_map(message) and is_map(parent_message) do
    if is_nil(message.reply_to_id) do
      message
      |> Ecto.Changeset.change(reply_to_id: parent_message.id)
      |> Elektrine.Repo.update()
    else
      :ok
    end
  end

  defp maybe_link_orphan_reply_to_parent(_, _), do: :ok

  defp build_poll_metadata(alt_texts, object, opts) do
    base = if map_size(alt_texts) > 0, do: %{"alt_texts" => alt_texts}, else: %{}

    base
    |> Map.merge(extract_community_metadata(object, opts))
  end

  defp build_metadata_with_engagement(alt_texts, object, opts) do
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

    # Persist community actor URI when present so UI/query layers can
    # reliably classify community posts even when the author is a Person.
    community_metadata = extract_community_metadata(object, opts)

    base
    |> Map.merge(engagement)
    |> Map.merge(reply_context)
    |> Map.merge(external_link)
    |> Map.merge(community_metadata)
  end

  defp extract_community_metadata(object, opts) do
    case detect_community_actor_uri(object, opts) do
      uri when is_binary(uri) -> %{"community_actor_uri" => uri}
      _ -> %{}
    end
  end

  defp detect_community_actor_uri(object, opts) when is_map(object) and is_list(opts) do
    author_uri =
      normalize_uri(object["attributedTo"] || Keyword.get(opts, :author_uri))

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

  # Walk the parent chain to recover community attribution for sparse activities.
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
  defp expand_uri_candidates(value) when is_list(value), do: value
  defp expand_uri_candidates(%{"id" => id}) when is_binary(id), do: [id]

  defp expand_uri_candidates(map) when is_map(map) do
    map
    |> Map.take(["id", "url", "href"])
    |> Map.values()
    |> Enum.flat_map(&expand_uri_candidates/1)
  end

  defp expand_uri_candidates(_), do: []

  defp validate_create_author(object, actor_uri) when is_map(object) do
    attributed_actor_uris =
      object["attributedTo"]
      |> expand_uri_candidates()
      |> Enum.map(&normalize_uri/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    normalized_actor_uri = normalize_uri(actor_uri)

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

  defp normalize_uri(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_uri(_), do: nil

  defp public_audience_uri?(uri) when is_binary(uri),
    do: Visibility.public_audience?(uri)

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

  # Extract external link from Lemmy/other link posts
  # Supports several common AP shapes used by Lemmy / PieFed / Mbin / others.
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
          "inReplyToAuthor" => extract_reply_author(in_reply_to, object["tag"])
        }

      # Object with id
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

  # Extract author handle from URL (fallback)
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

  # Normalize author to a display string
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
        ["users", _username, "statuses", post_id | _] ->
          post_id

        ["notice", post_id | _] ->
          post_id

        ["objects", post_id | _] ->
          post_id

        ["posts", post_id | _] ->
          post_id

        ["post", post_id | _] ->
          post_id

        ["comment", post_id | _] ->
          post_id

        ["comments", post_id | _] ->
          post_id

        ["activities", post_id | _] ->
          post_id

        [first, post_id | _] ->
          if String.starts_with?(first, "@"), do: post_id, else: nil

        _ ->
          nil
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

  # Extract a short content preview from the parent post if available
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

  defp do_upsert_federated_poll(message_id, object, options)
       when is_integer(message_id) and is_map(object) and is_list(options) do
    poll_attrs = build_poll_record_attrs(message_id, object, options)

    case Elektrine.Repo.get_by(Elektrine.Social.Poll, message_id: message_id) do
      nil ->
        poll_struct = :erlang.apply(Elektrine.Social.Poll, :__struct__, [])

        case Elektrine.Repo.insert(Elektrine.Social.Poll.changeset(poll_struct, poll_attrs)) do
          {:ok, poll} ->
            replace_poll_options(poll, options)
            {:ok, poll}

          {:error, reason} ->
            Logger.error("Failed to create federated poll: #{inspect(reason)}")
            {:error, reason}
        end

      poll ->
        case poll
             |> Elektrine.Social.Poll.changeset(Map.delete(poll_attrs, :message_id))
             |> Elektrine.Repo.update() do
          {:ok, updated_poll} ->
            replace_poll_options(updated_poll, options)
            {:ok, updated_poll}

          {:error, reason} ->
            Logger.error("Failed to update federated poll: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp do_upsert_federated_poll(_message_id, _object, _options), do: {:error, :invalid_poll}

  defp replace_poll_options(poll, options) do
    from(o in Elektrine.Social.PollOption, where: o.poll_id == ^poll.id)
    |> Elektrine.Repo.delete_all()

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
  end

  defp build_poll_record_attrs(message_id, object, options) do
    end_time =
      case object["endTime"] || object["closed"] do
        nil -> nil
        time_str -> Helpers.parse_published_date(time_str)
      end

    voters_count = extract_voters_count(object, options)

    %{
      message_id: message_id,
      question: extract_poll_question_text(object),
      total_votes: voters_count,
      voters_count: voters_count,
      closes_at: end_time,
      allow_multiple: !is_nil(object["anyOf"]),
      hide_totals: false,
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
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

  defp extract_poll_question_text(object) when is_map(object) do
    [object["question"], object["name"], object["content"]]
    |> Enum.find_value("", fn value ->
      normalized = strip_html(value || "", object["tag"])
      if normalized == "", do: nil, else: normalized
    end)
  end

  defp extract_poll_question_text(_), do: ""

  defp hashtag_source_content(content, question)
       when is_binary(content) and is_binary(question) do
    if Elektrine.Strings.present?(content), do: content, else: question
  end

  defp maybe_enrich_sparse_object(%{"id" => id} = object) when is_binary(id) do
    if sparse_object_payload?(object) do
      case Elektrine.ActivityPub.Fetcher.fetch_object(id) do
        {:ok, fetched} when is_map(fetched) ->
          merge_sparse_object_payload(object, fetched)

        _ ->
          object
      end
    else
      object
    end
  end

  defp maybe_enrich_sparse_object(object), do: object

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

  defp determine_visibility(object) do
    Visibility.visibility(object)
  end

  defp inherit_wrapper_fields(activity, object) when is_map(activity) and is_map(object) do
    ["to", "cc", "audience", "published"]
    |> Enum.reduce(object, fn field, acc ->
      inherit_wrapper_field(acc, activity, field)
    end)
  end

  defp inherit_wrapper_fields(_activity, object), do: object

  defp inherit_wrapper_field(object, activity, field) do
    case {Map.get(object, field), Map.get(activity, field)} do
      {value, inherited} when value in [nil, ""] and not is_nil(inherited) ->
        Map.put(object, field, inherited)

      {[], inherited} when not is_nil(inherited) ->
        Map.put(object, field, inherited)

      _ ->
        object
    end
  end

  defp deleted_object_recorded?(object, actor_uri) when is_map(object) and is_binary(actor_uri) do
    refs =
      [object["id"], object["url"]]
      |> Enum.reject(&is_nil/1)

    ActivityPub.remote_delete_recorded?(actor_uri, refs)
  end

  defp deleted_object_recorded?(_object, _actor_uri), do: false

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
    Elektrine.ActivityPub.local_username_from_uri(uri)
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
            url: Elektrine.Notifications.resolve_message_notification_url(message_id, "mention"),
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
      if Elektrine.Strings.present?(message.content) do
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

              _ =
                Elektrine.Repo.insert(
                  preview_changeset,
                  on_conflict: :nothing,
                  conflict_target: :url
                )

              case Elektrine.Repo.get_by(Social.LinkPreview, url: url) do
                %{id: id} when is_integer(id) ->
                  Messaging.update_message(message, %{link_preview_id: id})

                _ ->
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
        case Messaging.get_message_by_activitypub_ref(uri) do
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
