defmodule ElektrineWeb.API.NotificationController do
  @moduledoc """
  API controller for notifications.
  """
  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias ElektrineWeb.API.{AccountJSON, StatusJSON}

  action_fallback ElektrineWeb.FallbackController

  @status_source_types ["message", "post", "discussion"]

  @doc """
  GET /api/notifications
  Lists notifications for the current user.

  Query params:
    - limit: Number of notifications to return (default 50)
    - offset: Offset for pagination (default 0)
    - filter: "all", "unread", or "unseen" (default "all")
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]

    limit = parse_int(params["limit"], 50)
    offset = parse_int(params["offset"], 0)

    filter =
      case params["filter"] do
        "unread" -> :unread
        "unseen" -> :unseen
        _ -> :all
      end

    notifications =
      Notifications.list_notifications(user.id, limit: limit, offset: offset, filter: filter)

    unread_count = Notifications.get_visible_unread_count(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      notifications: render_notifications(notifications, user),
      unread_count: unread_count,
      limit: limit,
      offset: offset
    })
  end

  @doc """
  GET /api/v1/notifications
  Lists notifications in a client-compatible array shape.
  """
  def v1_index(conn, params) do
    user = conn.assigns[:current_user]

    limit = parse_int(params["limit"], 50)
    offset = parse_int(params["offset"], 0)

    filter =
      case params["filter"] do
        "unread" -> :unread
        "unseen" -> :unseen
        _ -> :all
      end

    notifications =
      Notifications.list_notifications(user.id, limit: limit, offset: offset, filter: filter)

    conn
    |> put_status(:ok)
    |> json(render_notifications(notifications, user))
  end

  @doc """
  GET /api/v1/notifications/:id
  Shows one notification.
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Notifications.get_notification(parse_int(id, 0), user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "notification not found"})

      notification ->
        conn
        |> put_status(:ok)
        |> json([notification] |> render_notifications(user) |> List.first())
    end
  end

  @doc """
  GET /api/v2/notifications/unread_count
  Returns the visible unread notification count.
  """
  def unread_count(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_status(:ok)
    |> json(%{count: Notifications.get_unread_group_count(user.id)})
  end

  @doc """
  GET /api/v2/notifications
  Lists notifications grouped by compatible group key.
  """
  def v2_index(conn, params) do
    user = conn.assigns[:current_user]

    groups =
      user.id
      |> Notifications.list_notification_groups(group_opts(params))
      |> Enum.take(parse_int(params["limit"], 20))

    conn
    |> put_status(:ok)
    |> json(format_grouped_notifications(groups, user))
  end

  @doc """
  GET /api/v2/notifications/:group_key
  Shows one grouped notification.
  """
  def show_group(conn, %{"group_key" => group_key}) do
    user = conn.assigns[:current_user]

    case Notifications.get_notification_group(user.id, group_key, group_opts(%{})) do
      {:ok, group} ->
        conn
        |> put_status(:ok)
        |> json(format_grouped_notifications([group], user, include_page_metadata: false))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "notification group not found"})
    end
  end

  @doc """
  GET /api/v2/notifications/:group_key/accounts
  Lists unique actors in a notification group.
  """
  def group_accounts(conn, %{"group_key" => group_key}) do
    user = conn.assigns[:current_user]

    accounts =
      user.id
      |> Notifications.list_notification_group_accounts(group_key)
      |> Enum.map(&format_actor/1)

    conn
    |> put_status(:ok)
    |> json(accounts)
  end

  @doc """
  POST /api/v2/notifications/:group_key/dismiss
  Dismisses all notifications in a group.
  """
  def dismiss_group(conn, %{"group_key" => group_key}) do
    user = conn.assigns[:current_user]

    _ = Notifications.dismiss_notification_group(user.id, group_key)

    conn
    |> put_status(:ok)
    |> json(%{})
  end

  @doc """
  POST /api/notifications/:id/read
  Marks a notification as read.
  """
  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    Notifications.mark_as_read(parse_int(id, 0), user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "Notification marked as read"})
  end

  @doc """
  POST /api/notifications/read-all
  Marks all notifications as read.
  """
  def mark_all_read(conn, _params) do
    user = conn.assigns[:current_user]

    Notifications.mark_all_as_read(user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "All notifications marked as read"})
  end

  def mark_read_via_body(conn, params) do
    user = conn.assigns[:current_user]

    cond do
      params["id"] || params[:id] ->
        Notifications.mark_as_read(parse_int(params["id"] || params[:id], 0), user.id)
        json(conn, "ok")

      params["max_id"] || params[:max_id] ->
        {:ok, _count} =
          Notifications.mark_as_read_up_to(
            user.id,
            parse_int(params["max_id"] || params[:max_id], 0)
          )

        json(conn, "ok")

      true ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "id or max_id required"})
    end
  end

  @doc """
  DELETE /api/notifications/:id
  Dismisses a notification.
  """
  def dismiss(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    Notifications.dismiss_notification(parse_int(id, 0), user.id)

    conn
    |> put_status(:ok)
    |> json(%{message: "Notification dismissed"})
  end

  @doc """
  POST /api/v1/notifications/clear
  Dismisses all notifications for the current user.
  """
  def clear(conn, _params) do
    user = conn.assigns[:current_user]

    Notifications.dismiss_all_notifications(user.id)

    conn
    |> put_status(:ok)
    |> json(%{})
  end

  @doc """
  DELETE /api/v1/notifications/destroy_multiple
  Dismisses multiple notifications for the current user.
  """
  def destroy_multiple(conn, params) do
    user = conn.assigns[:current_user]
    ids = notification_ids(params)

    {:ok, count} = Notifications.dismiss_notifications(ids, user.id)

    conn
    |> put_status(:ok)
    |> json(%{dismissed: count})
  end

  def dismiss_via_body(conn, params) do
    case params["id"] || params[:id] do
      nil -> destroy_multiple(conn, params)
      id -> dismiss(conn, %{"id" => id})
    end
  end

  # Private helpers

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp notification_ids(params) do
    []
    |> Kernel.++(List.wrap(params["ids"]))
    |> Kernel.++(List.wrap(params["id"]))
    |> Kernel.++(List.wrap(params["id[]"]))
    |> Enum.flat_map(&split_id_values/1)
  end

  defp split_id_values(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_id_values(value), do: List.wrap(value)

  defp group_opts(params) do
    [
      filter: notification_filter(params["filter"]),
      source_filter: params["source_filter"] || "all"
    ]
  end

  defp notification_filter("unread"), do: :unread
  defp notification_filter("unseen"), do: :unseen
  defp notification_filter(_), do: :all

  defp format_grouped_notifications(groups, viewer, opts \\ []) do
    accounts =
      groups
      |> Enum.flat_map(&group_actors/1)
      |> Enum.uniq_by(&actor_key/1)
      |> Enum.map(&format_actor/1)

    status_ids =
      groups
      |> Enum.map(&group_status_source_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    statuses_by_id = load_status_map(status_ids, viewer.id)

    statuses =
      status_ids
      |> Enum.map(&Map.get(statuses_by_id, to_string(&1)))
      |> Enum.reject(&is_nil/1)

    %{
      accounts: accounts,
      statuses: statuses,
      notification_groups: Enum.map(groups, &format_notification_group(&1, opts))
    }
  end

  defp group_status_source_id(group) do
    notifications = group_notifications(group)
    latest = group[:latest_notification] || List.first(notifications)

    case latest do
      %{source_type: source_type, source_id: source_id}
      when source_type in @status_source_types and is_integer(source_id) ->
        source_id

      _ ->
        nil
    end
  end

  defp format_notification_group(group, opts) do
    notifications = group_notifications(group)
    latest = group[:latest_notification] || List.first(notifications)
    oldest = List.last(notifications) || latest

    base = %{
      group_key: group[:group_key],
      notifications_count: group[:count] || length(notifications),
      type: notification_group_type(group, latest),
      most_recent_notification_id: notification_id(latest),
      sample_account_ids:
        group
        |> group_actors()
        |> Enum.map(&actor_account_id/1)
    }

    base
    |> maybe_put_group_status_id(latest)
    |> maybe_put_group_page_metadata(latest, oldest, opts)
  end

  defp notification_group_type(%{social_type: social_type}, _latest) when is_binary(social_type),
    do: social_type

  defp notification_group_type(_group, %{type: type}), do: type
  defp notification_group_type(_group, _latest), do: nil

  defp maybe_put_group_status_id(payload, %{source_type: source_type, source_id: source_id})
       when source_type in @status_source_types and is_integer(source_id) do
    Map.put(payload, :status_id, to_string(source_id))
  end

  defp maybe_put_group_status_id(payload, _latest), do: payload

  defp maybe_put_group_page_metadata(payload, _latest, _oldest, include_page_metadata: false),
    do: payload

  defp maybe_put_group_page_metadata(payload, latest, oldest, _opts) do
    Map.merge(payload, %{
      page_min_id: notification_id(oldest),
      page_max_id: notification_id(latest),
      latest_page_notification_at: latest && latest.inserted_at
    })
  end

  defp notification_id(%{id: id}), do: to_string(id)
  defp notification_id(_), do: nil

  defp group_notifications(%{notifications: notifications}) when is_list(notifications),
    do: notifications

  defp group_notifications(%{notification: notification}) when not is_nil(notification),
    do: [notification]

  defp group_notifications(_group), do: []

  defp group_actors(%{actors: actors}) when is_list(actors), do: Enum.reject(actors, &is_nil/1)
  defp group_actors(%{sender: sender}) when not is_nil(sender), do: [sender]

  defp group_actors(group) do
    group
    |> group_notifications()
    |> Enum.map(&Notifications.notification_actor/1)
    |> Enum.reject(&is_nil/1)
  end

  defp render_notifications(notifications, viewer) do
    statuses_by_id = statuses_for_notifications(notifications, viewer.id)

    notification_actors =
      Enum.map(notifications, &{&1, Notifications.notification_actor(&1)})

    actors =
      notification_actors
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&actor_key/1)

    accounts_by_key =
      actors
      |> Enum.zip(AccountJSON.format_accounts(actors, viewer))
      |> Map.new(fn {actor, account} -> {actor_key(actor), account} end)

    Enum.map(notification_actors, fn {notification, actor} ->
      format_notification(notification, actor, accounts_by_key, statuses_by_id)
    end)
  end

  defp statuses_for_notifications(notifications, viewer_id) do
    notifications
    |> Enum.flat_map(fn
      %{source_type: source_type, source_id: source_id}
      when source_type in @status_source_types and is_integer(source_id) ->
        [source_id]

      _notification ->
        []
    end)
    |> Enum.uniq()
    |> load_status_map(viewer_id)
  end

  defp load_status_map([], _viewer_id), do: %{}

  defp load_status_map(status_ids, viewer_id) do
    Message
    |> where([message], message.id in ^status_ids)
    |> preload(^Messages.timeline_feed_preloads())
    |> Repo.all()
    |> Enum.map(&Message.decrypt_content/1)
    |> then(&social().filter_explicit_visible_statuses(viewer_id, &1))
    |> StatusJSON.format_statuses(viewer_id)
    |> Map.new(&{&1.id, &1})
  end

  defp social, do: Module.concat([Elektrine, Social])

  defp format_notification(notification, actor, accounts_by_key, statuses_by_id) do
    %{
      id: notification.id,
      group_key: notification.group_key,
      type: notification.type,
      title: notification.title,
      body: notification.body,
      url: notification.url,
      icon: notification.icon,
      created_at: notification.inserted_at,
      read: not is_nil(notification.read_at),
      seen: not is_nil(notification.seen_at),
      actor: format_actor(actor),
      account: actor && Map.get(accounts_by_key, actor_key(actor)),
      status: notification_status(notification, statuses_by_id),
      source_type: notification.source_type,
      source_id: notification.source_id,
      inserted_at: notification.inserted_at,
      pleroma: %{
        is_seen: not is_nil(notification.seen_at),
        is_muted: false
      }
    }
  end

  defp notification_status(%{source_type: source_type, source_id: source_id}, statuses_by_id)
       when source_type in @status_source_types and is_integer(source_id) do
    Map.get(statuses_by_id, to_string(source_id))
  end

  defp notification_status(_notification, _statuses_by_id), do: nil

  defp format_actor(nil), do: nil

  defp format_actor(%Actor{} = actor) do
    %{
      id: "remote:#{actor.id}",
      username: actor.username,
      display_name: actor.display_name || actor.username,
      avatar_url: actor.avatar_url,
      acct: Enum.reject([actor.username, actor.domain], &is_nil/1) |> Enum.join("@"),
      remote: true
    }
  end

  defp format_actor(actor) do
    %{
      id: actor.id,
      username: actor.username,
      display_name: actor.display_name,
      avatar_url: Map.get(actor, :avatar_url) || Map.get(actor, :avatar),
      remote: false
    }
  end

  defp actor_key(%Actor{id: id}), do: {:remote, id}
  defp actor_key(%{id: id}), do: {:local, id}

  defp actor_account_id(%Actor{id: id}), do: "remote:#{id}"
  defp actor_account_id(%{id: id}), do: to_string(id)
end
