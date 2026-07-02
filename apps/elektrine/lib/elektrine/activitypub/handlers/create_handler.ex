defmodule Elektrine.ActivityPub.Handlers.CreateHandler do
  @moduledoc """
  Handles Create ActivityPub activities for Notes, Pages, Articles, and Questions.
  """

  require Logger

  import Ecto.Query

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers
  alias Elektrine.ActivityPub.Normalizer
  alias Elektrine.Async
  alias Elektrine.Emojis
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias Elektrine.Social.Poll

  @doc """
  Handles an incoming Create activity.
  """
  def handle(%{"object" => object} = activity, actor_ref, _target_user) when is_map(object) do
    actor_uri = Normalizer.actor_ref_uri(actor_ref)
    object = inherit_wrapper_fields(activity, object)
    activity_id = activity["id"] || object["id"]
    opts = ingestion_opts(activity)

    if is_binary(actor_uri) do
      case validate_object_author(object, actor_uri) do
        :ok ->
          case object["type"] do
            "Note" -> create_note(object, actor_uri, opts)
            "Page" -> create_note(object, actor_uri, opts)
            "Article" -> create_note(object, actor_uri, opts)
            "Question" -> create_question(object, actor_uri, opts)
            "Video" -> create_note(object, actor_uri, opts)
            # Akkoma/Pleroma explicitly sends Answer type for poll votes.
            "Answer" -> handle_incoming_poll_vote(object, actor_uri, activity_id: activity_id)
            _ -> {:ok, :unhandled}
          end

        {:error, :actor_mismatch} ->
          Logger.warning(
            "Rejecting Create #{inspect(activity_id)}: object attributedTo does not match verified actor #{actor_uri}"
          )

          {:ok, :unauthorized}
      end
    else
      Logger.warning("Rejecting Create #{inspect(activity_id)}: missing or invalid actor URI")
      {:error, :invalid_actor_uri}
    end
  end

  def handle(%{"object" => object_uri} = activity, actor_ref, target_user)
      when is_binary(object_uri) do
    actor_uri = Normalizer.actor_ref_uri(actor_ref)
    activity_id = activity["id"] || object_uri

    if is_binary(actor_uri) do
      case ActivityPub.RemoteFetch.fetch_object(object_uri) do
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
    else
      Logger.warning("Rejecting Create #{inspect(activity_id)}: missing or invalid actor URI")
      {:error, :invalid_actor_uri}
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
  def create_note(object, actor_ref, opts) when is_list(opts) do
    actor_uri = Normalizer.actor_ref_uri(actor_ref)

    with :ok <- validate_object_author(object, actor_uri) do
      if Normalizer.poll_vote?(object) do
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
    Normalizer.validate_object_author(object, actor_uri)
  end

  def validate_object_author(_object, _actor_uri), do: {:error, :actor_mismatch}

  @doc """
  Creates a Question (poll) from an ActivityPub object.
  """
  def create_question(object, actor_ref, opts \\ []) do
    actor_uri = Normalizer.actor_ref_uri(actor_ref)

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

              enqueue_home_feed_fanout(message.id)

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
    Normalizer.message_payload(object, actor_uri, opts)
  end

  @doc false
  def build_federated_question_payload(object, actor_uri, opts \\ []) when is_map(object) do
    Normalizer.question_payload(object, actor_uri, opts)
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
    upsert_federated_poll(message_id, object, Normalizer.poll_options(object))
  end

  def upsert_federated_poll(_message_id, _object), do: {:error, :invalid_poll}

  @doc false
  def upsert_federated_poll(message_id, object, options)
      when is_integer(message_id) and is_map(object) and is_list(options) do
    do_upsert_federated_poll(message_id, object, options)
  end

  def upsert_federated_poll(_message_id, _object, _options), do: {:error, :invalid_poll}

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
    object = Normalizer.enrich_sparse_object(object)

    if deleted_object_recorded?(object, actor_uri) do
      {:ok, :ignored_deleted_object}
    else
      with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
        payload =
          build_federated_message_payload(
            object,
            actor_uri,
            Keyword.put(opts, :enrich_sparse_object, false)
          )

        attrs = Map.merge(payload.attrs, %{federated: true, remote_actor_id: remote_actor.id})

        %URI{host: instance_domain} = URI.parse(actor_uri)
        Async.start(fn -> Emojis.process_activitypub_tags(object["tag"], instance_domain) end)

        if attrs.visibility in ["public", "unlisted"] do
          case Messaging.create_federated_message(attrs) do
            {:ok, message} ->
              enqueue_home_feed_fanout(message.id)

              handle_post_create_tasks(
                message,
                remote_actor,
                payload.hashtags,
                attrs.reply_to_id,
                payload.mentioned_local_users,
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
    if hashtags != [] do
      Async.run(fn -> link_hashtags_to_message(message.id, hashtags) end)
    end

    Async.start(fn -> generate_link_preview_for_message(message) end)

    if reply_to_id do
      Elektrine.ActivityPub.SideEffects.increment_reply_count(reply_to_id)

      Async.run(fn ->
        Elektrine.Notifications.FederationNotifications.notify_remote_reply(
          message.id,
          remote_actor.id
        )
      end)
    else
      Async.start(fn -> maybe_store_missing_reply_parent(message, remote_actor) end)
    end

    if mentioned_local_users != [] do
      Async.run(fn ->
        notify_mentioned_users(mentioned_local_users, message.id, remote_actor.id)
      end)
    end

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

  defp maybe_put_opt(opts, key, value) when is_integer(value), do: Keyword.put(opts, key, value)

  defp maybe_put_opt(opts, key, value) when is_binary(value) and value != "",
    do: Keyword.put(opts, key, value)

  defp maybe_put_opt(opts, _key, _value), do: opts

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

  defp enqueue_home_feed_fanout(message_id) when is_integer(message_id) do
    module = Module.concat([Elektrine.Social, HomeFeedFanoutWorker])
    _ = module.enqueue(message_id)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_store_missing_reply_parent(message, remote_actor) do
    metadata = Map.get(message, :media_metadata) || %{}

    in_reply_to_ref =
      metadata["inReplyTo"] ||
        metadata[:inReplyTo] ||
        metadata["in_reply_to"] ||
        metadata[:in_reply_to]

    normalized_ref = Normalizer.normalize_uri(in_reply_to_ref)

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
      question: Normalizer.poll_question_text(object) |> String.slice(0, 300),
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

  defp generate_link_preview_for_message(message) do
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
    case Messaging.get_message(parse_message_id(id)) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end

  defp parse_message_id(id) when is_integer(id), do: id

  defp parse_message_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> id
    end
  end

  defp parse_message_id(id), do: id
end
