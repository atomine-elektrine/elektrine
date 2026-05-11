defmodule Elektrine.ActivityPub.RepliesFetcher do
  @moduledoc """
  Proactively fetches and stores replies from ActivityPub reply collections.

  When viewing a remote post, this module fetches the replies collection
  and stores replies locally, similar to how Akkoma handles reply fetching.
  This ensures replies are available even when the remote server's collection
  doesn't expose counts.
  """

  require Logger

  import Ecto.Query

  alias Elektrine.ActivityPub

  alias Elektrine.ActivityPub.{
    Actor,
    CollectionFetcher,
    Helpers,
    LemmyApi,
    MastodonApi,
    Normalizer,
    RemoteFetch
  }

  alias Elektrine.Messaging
  alias Elektrine.Repo

  @max_replies 100
  @max_depth 3
  @max_pages 10
  @full_thread_max_replies 1000
  @full_thread_max_depth 5
  @full_thread_max_pages 50

  @doc """
  Fetches replies for a post and stores them locally.

  Called when viewing a remote post to ensure replies are available.
  Runs asynchronously to not block the page load.

  ## Parameters
  - `post_object` - The ActivityPub post object (must have "id" and optionally "replies")
  - `opts` - Options:
    - `:max_replies` - Maximum replies to fetch (default: #{@max_replies})
    - `:max_depth` - Maximum nesting depth to fetch (default: #{@max_depth})

  ## Returns
  - `{:ok, count}` - Number of replies stored
  - `{:error, reason}` - If fetching failed
  """
  def fetch_and_store_replies(post_object, opts \\ []) do
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)
    parent_ap_id = post_object["id"]
    replies_collection = post_object["replies"] || post_object["comments"]

    # Get or create the parent message
    parent_message = Messaging.get_message_by_activitypub_id(parent_ap_id)

    if is_nil(parent_message) do
      Logger.debug("Parent message not found for #{parent_ap_id}, skipping reply fetch")
      {:error, :parent_not_found}
    else
      do_fetch_and_store_replies(
        replies_collection,
        parent_message.id,
        max_replies,
        max_depth,
        max_pages,
        opts
      )
    end
  end

  @doc """
  Fetches replies for a message by its local ID.

  Useful when you have a message but need to refresh its replies.
  """
  def fetch_replies_for_message(message_id)
      when is_binary(message_id) or is_integer(message_id) do
    fetch_replies_for_message(message_id, [])
  end

  def fetch_replies_for_message(message_id, opts)
      when (is_binary(message_id) or is_integer(message_id)) and is_list(opts) do
    case Elektrine.Repo.get(Elektrine.Social.Message, message_id) do
      nil ->
        {:error, :message_not_found}

      message ->
        if message.activitypub_id do
          case RemoteFetch.fetch_object(message.activitypub_id, fetch_object_opts(opts)) do
            {:ok, post_object} ->
              case fetch_and_store_replies(post_object, opts) do
                {:ok, stored_count} ->
                  maybe_fetch_missing_replies_via_fallback(
                    post_object,
                    message.id,
                    opts,
                    stored_count
                  )

                {:error, _reason} ->
                  fetch_and_store_replies_via_fallback(post_object, message.id, opts)

                result ->
                  result
              end

            {:error, _reason} ->
              fetch_replies_without_post_object(message.activitypub_id, message.id, opts)
          end
        else
          {:error, :no_activitypub_id}
        end
    end
  end

  @doc """
  Backfills as much of a remote reply tree as possible within safety limits.
  """
  def fetch_full_thread_for_message(message_id, opts \\ []) do
    opts =
      Keyword.merge(
        [
          max_replies: @full_thread_max_replies,
          max_depth: @full_thread_max_depth,
          max_pages: @full_thread_max_pages
        ],
        opts
      )

    fetch_replies_for_message(message_id, opts)
  end

  @doc """
  Fetches replies from a collection URL directly.

  Use this when you have the replies collection URL but not the full post object.
  """
  def fetch_from_collection_url(collection_url, parent_message_id, opts \\ [])
      when is_binary(collection_url) do
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)

    do_fetch_and_store_replies(
      collection_url,
      parent_message_id,
      max_replies,
      max_depth,
      max_pages,
      opts
    )
  end

  # Private implementation

  defp do_fetch_and_store_replies(
         collection,
         parent_message_id,
         max_replies,
         max_depth,
         max_pages
       ) do
    do_fetch_and_store_replies(
      collection,
      parent_message_id,
      max_replies,
      max_depth,
      max_pages,
      []
    )
  end

  defp do_fetch_and_store_replies(
         nil,
         _parent_message_id,
         _max_replies,
         _max_depth,
         _max_pages,
         _opts
       ) do
    {:ok, 0}
  end

  defp do_fetch_and_store_replies(
         _collection,
         _parent_message_id,
         max_replies,
         _max_depth,
         _max_pages,
         _opts
       )
       when max_replies <= 0 do
    {:ok, 0}
  end

  defp do_fetch_and_store_replies(
         collection,
         parent_message_id,
         max_replies,
         max_depth,
         max_pages,
         opts
       )
       when is_binary(collection) or is_map(collection) do
    case CollectionFetcher.fetch_collection(collection,
           max_items: max_replies,
           max_pages: max_pages,
           skip_cache: Keyword.get(opts, :skip_cache, false),
           request_fun: Keyword.get(opts, :request_fun),
           sign: Keyword.get(opts, :sign),
           validate_url: Keyword.get(opts, :validate_url),
           allow_recovery: Keyword.get(opts, :allow_recovery)
         ) do
      {:ok, items} ->
        {stored_count, _remaining} =
          process_reply_items(items, parent_message_id, max_replies, max_depth, max_pages)

        Logger.debug("Stored #{stored_count} replies for message #{parent_message_id}")
        {:ok, stored_count}

      {:partial, items} ->
        {stored_count, _remaining} =
          process_reply_items(items, parent_message_id, max_replies, max_depth, max_pages)

        Logger.debug("Stored #{stored_count} partial replies for message #{parent_message_id}")
        {:ok, stored_count}

      {:error, reason} ->
        Logger.warning("Failed to fetch replies collection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_and_store_replies_via_fallback(post_object, parent_message_id, opts) do
    post_ref = post_object["id"] || post_object["url"]
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)

    cond do
      lemmy_comment_api_candidate?(post_ref) ->
        case LemmyApi.fetch_post_comments(post_ref, max_replies) do
          [] ->
            fetch_activitypub_replies_fallback(
              post_object,
              parent_message_id,
              max_replies,
              max_depth,
              max_pages,
              opts
            )

          replies ->
            process_fetched_reply_items(
              replies,
              parent_message_id,
              max_replies,
              max_depth,
              max_pages
            )
        end

      is_binary(post_ref) && MastodonApi.mastodon_compatible?(%{activitypub_id: post_ref}) ->
        case MastodonApi.fetch_status_context(post_ref) do
          {:ok, descendants} when is_list(descendants) ->
            replies =
              Enum.map(descendants, fn status ->
                %{
                  "id" => status.uri || status.url || "#{post_ref}#status-#{status.id}",
                  "url" => status.url || status.uri,
                  "type" => "Note",
                  "content" => status.content,
                  "attributedTo" => mastodon_status_actor_ref(status),
                  "_account" => status.account,
                  "published" => status.created_at,
                  "inReplyTo" => status.in_reply_to_uri,
                  "likes" => %{"totalItems" => status.favourites_count || 0},
                  "shares" => %{"totalItems" => status.reblogs_count || 0},
                  "replies" => %{"totalItems" => status.replies_count || 0}
                }
              end)

            {stored_count, _remaining} =
              process_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)

            {:ok, stored_count}

          _ ->
            {:ok, 0}
        end

      true ->
        fetch_activitypub_replies_fallback(
          post_object,
          parent_message_id,
          max_replies,
          max_depth,
          max_pages,
          opts
        )
    end
  end

  defp fetch_replies_without_post_object(post_ref, parent_message_id, opts)
       when is_binary(post_ref) do
    max_replies = Keyword.get(opts, :max_replies, @max_replies)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_pages = Keyword.get(opts, :max_pages, @max_pages)

    cond do
      lemmy_comment_api_candidate?(post_ref) ->
        replies = LemmyApi.fetch_post_comments(post_ref, max_replies)

        process_fetched_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)

      MastodonApi.mastodon_compatible?(%{activitypub_id: post_ref}) ->
        case MastodonApi.fetch_status_context(post_ref) do
          {:ok, descendants} when is_list(descendants) ->
            replies =
              Enum.map(descendants, fn status ->
                %{
                  "id" => status.uri || status.url || "#{post_ref}#status-#{status.id}",
                  "url" => status.url || status.uri,
                  "type" => "Note",
                  "content" => status.content,
                  "attributedTo" => mastodon_status_actor_ref(status),
                  "_account" => status.account,
                  "published" => status.created_at,
                  "inReplyTo" => status.in_reply_to_uri,
                  "likes" => %{"totalItems" => status.favourites_count || 0},
                  "shares" => %{"totalItems" => status.reblogs_count || 0},
                  "replies" => %{"totalItems" => status.replies_count || 0}
                }
              end)

            {stored_count, _remaining} =
              process_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)

            {:ok, stored_count}

          _ ->
            {:ok, 0}
        end

      true ->
        {:error, :fetch_failed}
    end
  end

  defp process_reply_items(items, parent_message_id, remaining_budget, max_depth, max_pages) do
    Enum.reduce_while(items, {0, remaining_budget}, fn item, {stored_count, remaining} ->
      if remaining <= 0 do
        {:halt, {stored_count, 0}}
      else
        normalized_item = normalize_reply_item(item)

        {item_stored_count, item_remaining} =
          process_reply_item(normalized_item, parent_message_id, remaining, max_depth, max_pages)

        {:cont, {stored_count + item_stored_count, item_remaining}}
      end
    end)
  end

  defp process_fetched_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)
       when is_list(replies) do
    {stored_count, _remaining} =
      process_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)

    {:ok, stored_count}
  end

  defp process_fetched_reply_items(_, _parent_message_id, _max_replies, _max_depth, _max_pages),
    do: {:ok, 0}

  defp fetch_activitypub_replies_fallback(
         post_object,
         parent_message_id,
         max_replies,
         max_depth,
         max_pages,
         opts
       ) do
    fetch_opts = Keyword.merge(opts, limit: max_replies)

    case ActivityPub.fetch_remote_post_replies(post_object, fetch_opts) do
      {:ok, replies} when is_list(replies) ->
        process_fetched_reply_items(replies, parent_message_id, max_replies, max_depth, max_pages)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_fetch_missing_replies_via_fallback(
         post_object,
         parent_message_id,
         opts,
         stored_count
       ) do
    if stored_count == 0 || reply_count_below_expected?(post_object, parent_message_id) do
      case fetch_and_store_replies_via_fallback(post_object, parent_message_id, opts) do
        {:ok, fallback_count} ->
          {:ok, stored_count + fallback_count}

        {:error, reason} when stored_count > 0 ->
          Logger.debug(
            "Reply fallback failed after storing #{stored_count} replies for #{parent_message_id}: #{inspect(reason)}"
          )

          {:ok, stored_count}

        error ->
          error
      end
    else
      {:ok, stored_count}
    end
  end

  defp reply_count_below_expected?(post_object, parent_message_id) do
    expected_count = expected_reply_count(post_object)

    expected_count > 0 &&
      stored_reply_descendant_count(parent_message_id, expected_count) < expected_count
  end

  defp expected_reply_count(post_object) when is_map(post_object) do
    [
      post_object["reply_count"],
      post_object["repliesCount"],
      collection_total_items(post_object["replies"]),
      collection_total_items(post_object["comments"])
    ]
    |> Enum.map(&normalize_count/1)
    |> Enum.max(fn -> 0 end)
  end

  defp expected_reply_count(_), do: 0

  defp collection_total_items(%{"totalItems" => total}), do: total
  defp collection_total_items(%{totalItems: total}), do: total
  defp collection_total_items(_), do: nil

  defp normalize_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_count(_), do: 0

  defp stored_reply_descendant_count(parent_message_id, expected_count)
       when is_integer(parent_message_id) do
    max_scan = max(expected_count, 1) |> min(5000)
    do_stored_reply_descendant_count([parent_message_id], MapSet.new(), 0, max_scan)
  end

  defp stored_reply_descendant_count(_, _), do: 0

  defp do_stored_reply_descendant_count(_parent_ids, _seen_ids, count, max_scan)
       when count >= max_scan,
       do: count

  defp do_stored_reply_descendant_count(parent_ids, seen_ids, count, max_scan)
       when is_list(parent_ids) do
    pending_parent_ids =
      parent_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if pending_parent_ids == [] do
      count
    else
      reply_ids =
        Elektrine.Social.Message
        |> where([m], m.reply_to_id in ^pending_parent_ids and is_nil(m.deleted_at))
        |> select([m], m.id)
        |> Repo.all()

      new_reply_ids = Enum.reject(reply_ids, &MapSet.member?(seen_ids, &1))
      new_count = min(count + length(new_reply_ids), max_scan)
      next_seen_ids = Enum.reduce(new_reply_ids, seen_ids, &MapSet.put(&2, &1))

      do_stored_reply_descendant_count(new_reply_ids, next_seen_ids, new_count, max_scan)
    end
  end

  defp fetch_object_opts(opts) do
    opts
    |> Keyword.take([:request_fun, :skip_cache, :sign, :validate_url])
    |> case do
      fetch_opts ->
        case Keyword.get(fetch_opts, :request_fun) do
          request_fun when is_function(request_fun, 3) -> fetch_opts
          nil -> fetch_opts
          _ -> Keyword.delete(fetch_opts, :request_fun)
        end
    end
  end

  defp lemmy_comment_api_candidate?(post_ref) when is_binary(post_ref) do
    LemmyApi.community_post_url?(post_ref) || LemmyApi.fetch_post_counts(post_ref) != nil
  end

  defp lemmy_comment_api_candidate?(_), do: false

  defp process_reply_item(nil, _parent_message_id, remaining_budget, _max_depth, _max_pages),
    do: {0, remaining_budget}

  defp process_reply_item(object, parent_message_id, remaining_budget, max_depth, max_pages) do
    case store_reply(object, parent_message_id) do
      {:stored, reply_message} ->
        nested_budget = remaining_budget - 1

        {nested_count, final_remaining} =
          maybe_fetch_nested_replies(object, reply_message, nested_budget, max_depth, max_pages)

        {1 + nested_count, final_remaining}

      {:existing, reply_message} when is_map(reply_message) ->
        maybe_fetch_nested_replies(object, reply_message, remaining_budget, max_depth, max_pages)

      _ ->
        {0, remaining_budget}
    end
  end

  defp maybe_fetch_nested_replies(
         _object,
         _reply_message,
         remaining_budget,
         max_depth,
         _max_pages
       )
       when remaining_budget <= 0 or max_depth <= 1 do
    {0, remaining_budget}
  end

  defp maybe_fetch_nested_replies(object, reply_message, remaining_budget, max_depth, max_pages) do
    replies_collection = object["replies"] || object["comments"]

    case replies_collection do
      nil ->
        {0, remaining_budget}

      _ ->
        case do_fetch_and_store_replies(
               replies_collection,
               reply_message.id,
               remaining_budget,
               max_depth - 1,
               max_pages
             ) do
          {:ok, stored_count} -> {stored_count, max(remaining_budget - stored_count, 0)}
          {:error, _reason} -> {0, remaining_budget}
        end
    end
  end

  # Normalize different reply item formats
  defp normalize_reply_item(item) when is_binary(item) do
    # Just a URL reference - need to fetch the full object
    case RemoteFetch.fetch_object(item) do
      {:ok, object} -> object
      {:error, _} -> nil
    end
  end

  defp normalize_reply_item(%{"type" => type} = item)
       when type in ["Note", "Article", "Page", "Question"] do
    item
  end

  defp normalize_reply_item(%{"object" => object}) when is_map(object) do
    # Wrapped in a Create activity
    normalize_reply_item(object)
  end

  defp normalize_reply_item(%{"object" => object_url}) when is_binary(object_url) do
    # Create activity with object URL
    case RemoteFetch.fetch_object(object_url) do
      {:ok, object} -> object
      {:error, _} -> nil
    end
  end

  defp normalize_reply_item(_), do: nil

  defp store_reply(object, parent_message_id) do
    actor_uri = Normalizer.actor_uri(object)

    if is_nil(actor_uri) do
      Logger.debug("Reply has no author, skipping: #{object["id"]}")
      :skip
    else
      case ActivityPub.get_or_fetch_actor(actor_uri) do
        {:ok, remote_actor} ->
          resolved_parent_message_id = resolve_parent_message_id(object, parent_message_id)
          create_reply_message(object, remote_actor, resolved_parent_message_id)

        {:error, reason} ->
          case fallback_remote_actor(object, actor_uri) do
            %Actor{} = remote_actor ->
              Logger.debug(
                "Using fallback actor for #{actor_uri} after fetch failure: #{inspect(reason)}"
              )

              resolved_parent_message_id = resolve_parent_message_id(object, parent_message_id)
              create_reply_message(object, remote_actor, resolved_parent_message_id)

            _ ->
              Logger.debug("Failed to fetch actor #{actor_uri}: #{inspect(reason)}")
              :error
          end
      end
    end
  rescue
    e ->
      Logger.warning("Error storing reply: #{inspect(e)}")
      :error
  end

  defp create_reply_message(object, remote_actor, parent_message_id) do
    # Check if already exists
    case Messaging.get_message_by_activitypub_id(object["id"]) do
      nil ->
        payload =
          Normalizer.message_payload(object, remote_actor.uri,
            enrich_sparse_object: false,
            assume_public_reply_without_audience: true
          )

        visibility = payload.attrs.visibility

        if visibility in ["public", "unlisted"] do
          attrs =
            payload.attrs
            |> Map.merge(reply_count_attrs(object))
            |> Map.merge(%{
              federated: true,
              remote_actor_id: remote_actor.id,
              reply_to_id: parent_message_id
            })

          case Messaging.create_federated_message(attrs) do
            {:ok, message} ->
              # Increment parent's reply count
              Elektrine.ActivityPub.SideEffects.increment_reply_count(parent_message_id)

              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "timeline:public",
                {:new_public_post,
                 Repo.preload(message, [:remote_actor, :sender, :link_preview, :hashtags])}
              )

              {:stored, message}

            {:error, %Ecto.Changeset{errors: [activitypub_id: {"has already been taken", _}]}} ->
              {:existing,
               object["id"]
               |> Messaging.get_message_by_activitypub_id()
               |> refresh_existing_reply_counts(object)}

            {:error, reason} ->
              Logger.debug("Failed to create reply: #{inspect(reason)}")
              :error
          end
        else
          :skip
        end

      existing ->
        {:existing, refresh_existing_reply_counts(existing, object)}
    end
  end

  defp refresh_existing_reply_counts(message, object) when is_map(message) and is_map(object) do
    attrs = reply_count_attrs(object)

    if reply_count_attrs_changed?(message, attrs) do
      case Elektrine.Social.Messages.update_message_metadata(message, attrs) do
        {:ok, updated_message} -> updated_message
        _ -> message
      end
    else
      message
    end
  end

  defp refresh_existing_reply_counts(message, _), do: message

  defp reply_count_attrs(object) when is_map(object) do
    object
    |> Normalizer.engagement_counts()
    |> Map.take([:like_count, :reply_count, :share_count, :upvotes, :downvotes, :score])
  end

  defp reply_count_attrs(_), do: %{}

  defp reply_count_attrs_changed?(message, attrs) when is_map(message) and is_map(attrs) do
    (message.like_count || 0) != (attrs[:like_count] || 0) ||
      (message.reply_count || 0) != (attrs[:reply_count] || 0) ||
      (message.share_count || 0) != (attrs[:share_count] || 0) ||
      (message.upvotes || 0) != (attrs[:upvotes] || 0) ||
      (message.downvotes || 0) != (attrs[:downvotes] || 0) ||
      (message.score || 0) != (attrs[:score] || 0)
  end

  defp reply_count_attrs_changed?(_, _), do: false

  defp resolve_parent_message_id(object, fallback_parent_message_id) when is_map(object) do
    in_reply_to_ref = normalize_in_reply_to_ref(object["inReplyTo"])

    cond do
      !is_binary(in_reply_to_ref) or in_reply_to_ref == "" ->
        fallback_parent_message_id

      parent = Messaging.get_message_by_activitypub_ref(in_reply_to_ref) ->
        parent.id

      true ->
        actor_uri = Normalizer.actor_uri(object)

        case Helpers.get_or_store_remote_post(in_reply_to_ref, actor_uri) do
          {:ok, parent} when is_map(parent) -> parent.id
          _ -> fallback_parent_message_id
        end
    end
  end

  defp resolve_parent_message_id(_, fallback_parent_message_id), do: fallback_parent_message_id

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)
  defp normalize_in_reply_to_ref(value) when is_binary(value), do: String.trim(value)
  defp normalize_in_reply_to_ref(_), do: nil

  defp mastodon_status_actor_ref(status) when is_map(status) do
    account = Map.get(status, :account) || %{}

    case account[:uri] || account["uri"] do
      uri when is_binary(uri) and uri != "" ->
        uri

      _ ->
        normalize_mastodon_profile_url(account[:url] || account["url"])
    end
  end

  defp mastodon_status_actor_ref(_), do: nil

  defp fallback_remote_actor(%{"_account" => account}, actor_uri) when is_map(account) do
    create_or_get_fallback_actor(actor_uri, account)
  end

  defp fallback_remote_actor(_, _), do: nil

  defp create_or_get_fallback_actor(actor_uri, account)
       when is_binary(actor_uri) and is_map(account) do
    username = account[:username] || account["username"]
    acct = account[:acct] || account["acct"]
    actor_url = account[:url] || account["url"]
    avatar = account[:avatar] || account["avatar"]
    display_name = account[:display_name] || account["display_name"] || username
    domain = actor_domain_from_acct_or_uri(acct, actor_uri)

    cond do
      existing = ActivityPub.get_actor_by_uri(actor_uri) ->
        existing

      !is_binary(username) or username == "" or !is_binary(domain) or domain == "" ->
        nil

      existing = ActivityPub.get_actor_by_username_and_domain(username, domain) ->
        existing

      true ->
        attrs = %{
          uri: actor_uri,
          username: username,
          domain: domain,
          display_name: display_name,
          avatar_url: avatar,
          inbox_url: fallback_actor_inbox(actor_uri),
          outbox_url: fallback_actor_outbox(actor_uri),
          public_key: "placeholder-public-key",
          actor_type: "Person",
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{
            "acct" => acct,
            "url" => actor_url,
            "fallback" => true
          }
        }

        %Actor{}
        |> Actor.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:display_name, :avatar_url, :last_fetched_at, :metadata]},
          conflict_target: :uri,
          returning: true
        )
        |> case do
          {:ok, actor} -> actor
          _ -> ActivityPub.get_actor_by_uri(actor_uri)
        end
    end
  end

  defp create_or_get_fallback_actor(_, _), do: nil

  defp actor_domain_from_acct_or_uri(acct, actor_uri) when is_binary(acct) do
    case String.split(acct, "@", parts: 2) do
      [_username, domain] when domain != "" -> domain
      _ -> actor_domain_from_uri(actor_uri)
    end
  end

  defp actor_domain_from_acct_or_uri(_, actor_uri), do: actor_domain_from_uri(actor_uri)

  defp actor_domain_from_uri(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp actor_domain_from_uri(_), do: nil

  defp fallback_actor_inbox(actor_uri) when is_binary(actor_uri), do: actor_uri <> "/inbox"
  defp fallback_actor_inbox(_), do: nil

  defp fallback_actor_outbox(actor_uri) when is_binary(actor_uri), do: actor_uri <> "/outbox"
  defp fallback_actor_outbox(_), do: nil

  defp normalize_mastodon_profile_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) and is_binary(path) ->
        if String.starts_with?(path, "/@") do
          "#{scheme}://#{host}/users/#{String.trim_leading(path, "/@")}"
        else
          url
        end

      _ ->
        nil
    end
  end

  defp normalize_mastodon_profile_url(_), do: nil
end
