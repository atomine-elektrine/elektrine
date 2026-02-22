defmodule Elektrine.Bluesky.Inbound do
  @moduledoc """
  Polls Bluesky notifications and mirrors inbound interactions back into Elektrine notifications.

  Current behavior:
  - Tracks reply/mention/quote/like/repost events targeting mirrored posts.
  - Deduplicates events with `bluesky_inbound_events`.
  - Creates local notifications for the owner of the related local post.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Elektrine.Accounts.User
  alias Elektrine.Bluesky
  alias Elektrine.Bluesky.InboundEvent
  alias Elektrine.Messaging.Message
  alias Elektrine.Notifications
  alias Elektrine.Repo

  @default_limit 50
  @default_feed_limit 50
  @default_timeout_ms 12_000
  @supported_reasons ~w(reply mention quote like repost)

  @doc """
  Sync inbound Bluesky notifications for all users with Bluesky enabled.
  """
  def sync_enabled_users do
    if inbound_enabled?() do
      users = inbound_enabled_users()

      summary =
        Enum.reduce(
          users,
          %{users: 0, processed_events: 0, created_notifications: 0, synced_feed_posts: 0},
          fn user, acc ->
            case sync_user(user) do
              {:ok, result} ->
                %{
                  users: acc.users + 1,
                  processed_events: acc.processed_events + result.processed_events,
                  created_notifications: acc.created_notifications + result.created_notifications,
                  synced_feed_posts: acc.synced_feed_posts + result.synced_feed_posts
                }

              {:skipped, _reason} ->
                %{acc | users: acc.users + 1}

              {:error, reason} ->
                Logger.warning(
                  "Bluesky inbound sync failed for user #{user.id}/#{user.username}: #{inspect(reason)}"
                )

                %{acc | users: acc.users + 1}
            end
          end
        )

      {:ok, summary}
    else
      {:skipped, :inbound_disabled}
    end
  end

  @doc """
  Sync inbound Bluesky notifications for a single user.
  """
  def sync_user(%User{} = user) do
    if inbound_enabled?() do
      with {:ok, session} <- Bluesky.session_for_user(user),
           {:ok, payload} <- list_notifications(session, user.bluesky_inbound_cursor),
           {:ok, notification_result} <-
             process_notifications(user, payload["notifications"] || []),
           {:ok, feed_result} <- sync_feed_posts(user, session) do
        update_poll_tracking(user.id, payload["cursor"])

        {:ok,
         %{
           processed_events: notification_result.processed_events,
           created_notifications: notification_result.created_notifications,
           synced_feed_posts: feed_result.synced_feed_posts
         }}
      end
    else
      {:skipped, :inbound_disabled}
    end
  end

  defp inbound_enabled_users do
    from(u in User,
      where:
        u.bluesky_enabled == true and
          not is_nil(u.bluesky_identifier) and
          not is_nil(u.bluesky_app_password)
    )
    |> Repo.all()
  end

  defp list_notifications(session, cursor) do
    params =
      %{"limit" => Integer.to_string(inbound_limit())}
      |> maybe_put_cursor(cursor)

    url =
      session.service_url <>
        "/xrpc/app.bsky.notification.listNotifications?" <> URI.encode_query(params)

    headers = [
      {"accept", "application/json"},
      {"authorization", "Bearer " <> session.access_jwt}
    ]

    timeout_ms = Keyword.get(bluesky_config(), :timeout_ms, @default_timeout_ms)

    case http_client().request(:get, url, headers, "", receive_timeout: timeout_ms) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _ -> {:error, :invalid_notifications_payload}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:notifications_request_failed, status}}

      {:error, reason} ->
        {:error, {:notifications_http_error, reason}}
    end
  end

  defp maybe_put_cursor(params, cursor) when is_binary(cursor) and cursor != "" do
    Map.put(params, "cursor", cursor)
  end

  defp maybe_put_cursor(params, _cursor), do: params

  defp sync_feed_posts(user, session) do
    if feed_sync_enabled?() do
      with {:ok, payload} <- list_timeline(session),
           {:ok, result} <- process_feed_posts(user, payload["feed"] || []) do
        {:ok, result}
      end
    else
      {:ok, %{synced_feed_posts: 0}}
    end
  end

  defp list_timeline(session) do
    params = %{"limit" => Integer.to_string(feed_limit())}

    url =
      session.service_url <>
        "/xrpc/app.bsky.feed.getTimeline?" <> URI.encode_query(params)

    headers = [
      {"accept", "application/json"},
      {"authorization", "Bearer " <> session.access_jwt}
    ]

    timeout_ms = Keyword.get(bluesky_config(), :timeout_ms, @default_timeout_ms)

    case http_client().request(:get, url, headers, "", receive_timeout: timeout_ms) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _ -> {:error, :invalid_timeline_payload}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:timeline_request_failed, status}}

      {:error, reason} ->
        {:error, {:timeline_http_error, reason}}
    end
  end

  defp process_feed_posts(user, feed_items) when is_list(feed_items) do
    feed_items
    |> Enum.reduce({:ok, %{synced_feed_posts: 0}}, fn feed_item, {:ok, acc} ->
      case process_feed_post(user, feed_item) do
        :ok ->
          {:ok, %{synced_feed_posts: acc.synced_feed_posts + 1}}

        {:skip, _reason} ->
          {:ok, acc}

        {:error, reason} ->
          Logger.warning(
            "Bluesky inbound feed processing failed for user #{user.id}: #{inspect(reason)}"
          )

          {:ok, acc}
      end
    end)
  end

  defp process_feed_posts(_user, _feed_items), do: {:ok, %{synced_feed_posts: 0}}

  defp process_feed_post(%User{} = user, feed_item) when is_map(feed_item) do
    with {:ok, post_uri} <- feed_post_uri(feed_item),
         {:ok, event_id} <- feed_event_id(post_uri),
         {:ok, raw_feed_event} <- build_feed_event_payload(feed_item, post_uri),
         :ok <- track_event(user.id, event_id, "feed_post", post_uri, raw_feed_event) do
      :ok
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_feed_post(_user, _feed_item), do: {:skip, :invalid_feed_item}

  defp feed_post_uri(feed_item) do
    case get_in(feed_item, ["post", "uri"]) do
      uri when is_binary(uri) and uri != "" -> {:ok, uri}
      _ -> {:skip, :missing_feed_uri}
    end
  end

  defp feed_event_id(post_uri) do
    {:ok, "feed:" <> post_uri}
  end

  defp build_feed_event_payload(feed_item, post_uri) do
    post = feed_item["post"] || %{}

    {:ok,
     %{
       "uri" => post_uri,
       "cid" => post["cid"],
       "indexedAt" => post["indexedAt"] || feed_item["indexedAt"],
       "author" => post["author"],
       "record" => post["record"],
       "embed" => post["embed"],
       "replyCount" => post["replyCount"],
       "repostCount" => post["repostCount"],
       "likeCount" => post["likeCount"],
       "quoteCount" => post["quoteCount"]
     }}
  end

  defp process_notifications(user, notifications) when is_list(notifications) do
    notifications
    |> Enum.reverse()
    |> Enum.reduce({:ok, %{processed_events: 0, created_notifications: 0}}, fn notification,
                                                                               {:ok, acc} ->
      case process_notification(user, notification) do
        {:ok, created_notification?} ->
          {:ok,
           %{
             processed_events: acc.processed_events + 1,
             created_notifications:
               acc.created_notifications + if(created_notification?, do: 1, else: 0)
           }}

        {:skip, _reason} ->
          {:ok, acc}

        {:error, reason} ->
          Logger.warning(
            "Bluesky inbound notification processing failed for user #{user.id}: #{inspect(reason)}"
          )

          {:ok, acc}
      end
    end)
  end

  defp process_notifications(_user, _notifications),
    do: {:ok, %{processed_events: 0, created_notifications: 0}}

  defp process_notification(%User{} = user, notification) when is_map(notification) do
    with {:ok, reason} <- extract_reason(notification),
         {:ok, event_id} <- extract_event_id(notification),
         {:ok, subject_uri} <- extract_subject_uri(notification),
         {:ok, local_message} <- find_local_message(subject_uri),
         :ok <- ensure_message_owner(local_message, user.id),
         :ok <- track_event(user.id, event_id, reason, subject_uri, notification),
         :ok <- create_local_notification(user, local_message, reason, notification, subject_uri) do
      {:ok, true}
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_notification(_user, _notification), do: {:skip, :invalid_notification}

  defp extract_reason(notification) do
    reason = notification["reason"]

    cond do
      not is_binary(reason) -> {:skip, :missing_reason}
      reason not in @supported_reasons -> {:skip, :unsupported_reason}
      true -> {:ok, reason}
    end
  end

  defp extract_event_id(notification) do
    case notification["uri"] || notification["cid"] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        author_did = get_in(notification, ["author", "did"]) || "unknown"
        reason = notification["reason"] || "unknown"
        indexed_at = notification["indexedAt"] || "unknown"
        subject = notification["reasonSubject"] || "unknown"
        {:ok, "#{author_did}|#{reason}|#{indexed_at}|#{subject}"}
    end
  end

  defp extract_subject_uri(notification) do
    case notification["reasonSubject"] do
      uri when is_binary(uri) and uri != "" -> {:ok, uri}
      _ -> {:skip, :missing_reason_subject}
    end
  end

  defp find_local_message(subject_uri) do
    case Repo.get_by(Message, bluesky_uri: subject_uri) do
      %Message{} = message -> {:ok, message}
      nil -> {:skip, :subject_not_local}
    end
  end

  defp ensure_message_owner(%Message{sender_id: sender_id}, user_id)
       when is_integer(sender_id) and sender_id == user_id,
       do: :ok

  defp ensure_message_owner(_message, _user_id), do: {:skip, :subject_owned_by_another_user}

  defp track_event(user_id, event_id, reason, subject_uri, raw_notification) do
    metadata =
      %{
        "author" => raw_notification["author"],
        "uri" => raw_notification["uri"],
        "cid" => raw_notification["cid"],
        "indexedAt" => raw_notification["indexedAt"]
      }
      |> Map.merge(%{"payload" => raw_notification})

    attrs = %{
      user_id: user_id,
      event_id: event_id,
      reason: reason,
      related_post_uri: subject_uri,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: metadata
    }

    case %InboundEvent{} |> InboundEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _event} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_violation?(changeset) do
          {:skip, :duplicate_event}
        else
          {:error, {:event_tracking_failed, changeset.errors}}
        end
    end
  end

  defp unique_constraint_violation?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp create_local_notification(user, local_message, reason, raw_notification, subject_uri) do
    author = raw_notification["author"] || %{}
    author_handle = author["handle"] || author["did"] || "unknown"

    {type, title, body, priority} =
      notification_content(reason, author_handle, raw_notification["record"] || %{})

    attrs = %{
      type: type,
      title: title,
      body: body,
      user_id: user.id,
      source_type: "bluesky",
      source_id: local_message.id,
      url: bluesky_post_url(raw_notification["uri"]) || bluesky_post_url(subject_uri),
      icon: "hero-globe-alt",
      priority: priority,
      metadata: %{
        "bluesky_reason" => reason,
        "bluesky_author" => author,
        "bluesky_uri" => raw_notification["uri"],
        "bluesky_reason_subject" => subject_uri
      }
    }

    case Notifications.create_notification(attrs) do
      {:ok, _notification} -> :ok
      {:error, changeset} -> {:error, {:create_notification_failed, changeset.errors}}
    end
  end

  defp notification_content("reply", author_handle, record) do
    body = text_or_default(record["text"], "Someone replied on Bluesky.")
    {"reply", "New Bluesky reply from @#{author_handle}", body, "normal"}
  end

  defp notification_content("mention", author_handle, record) do
    body = text_or_default(record["text"], "Someone mentioned your post on Bluesky.")
    {"mention", "New Bluesky mention from @#{author_handle}", body, "normal"}
  end

  defp notification_content("quote", author_handle, record) do
    body = text_or_default(record["text"], "Someone quoted your mirrored post on Bluesky.")
    {"comment", "Your post was quoted by @#{author_handle}", body, "normal"}
  end

  defp notification_content("like", author_handle, _record) do
    {"like", "New Bluesky like from @#{author_handle}", "Your mirrored post received a like.",
     "low"}
  end

  defp notification_content("repost", author_handle, _record) do
    {"system", "New Bluesky repost from @#{author_handle}", "Your mirrored post was reposted.",
     "low"}
  end

  defp text_or_default(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      text -> String.slice(text, 0, 300)
    end
  end

  defp text_or_default(_value, default), do: default

  defp bluesky_post_url("at://" <> rest) do
    case String.split(rest, "/") do
      [repo, "app.bsky.feed.post", rkey | _] ->
        "https://bsky.app/profile/#{repo}/post/#{rkey}"

      _ ->
        nil
    end
  end

  defp bluesky_post_url(uri) when is_binary(uri) and uri != "", do: uri
  defp bluesky_post_url(_uri), do: nil

  defp update_poll_tracking(user_id, cursor) do
    updates =
      [bluesky_inbound_last_polled_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      |> maybe_add_cursor_update(cursor)

    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: updates)

    :ok
  end

  defp maybe_add_cursor_update(updates, cursor) when is_binary(cursor) and cursor != "" do
    Keyword.put(updates, :bluesky_inbound_cursor, cursor)
  end

  defp maybe_add_cursor_update(updates, _cursor), do: updates

  defp inbound_enabled? do
    Keyword.get(bluesky_config(), :inbound_enabled, false)
  end

  defp feed_sync_enabled? do
    Keyword.get(bluesky_config(), :inbound_feed_enabled, true)
  end

  defp inbound_limit do
    max(1, Keyword.get(bluesky_config(), :inbound_limit, @default_limit))
  end

  defp feed_limit do
    max(1, Keyword.get(bluesky_config(), :inbound_feed_limit, @default_feed_limit))
  end

  defp bluesky_config, do: Application.get_env(:elektrine, :bluesky, [])

  defp http_client do
    Keyword.get(bluesky_config(), :http_client, Elektrine.Bluesky.FinchClient)
  end
end
