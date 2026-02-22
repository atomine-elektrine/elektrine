defmodule ElektrineWeb.Admin.ModerationController do
  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def content(conn, params) do
    content_type = params["type"] || "timeline"
    page = SafeConvert.parse_page(params)
    per_page = 50
    offset = (page - 1) * per_page
    search_query = params["search"] || ""

    # Build query based on content type
    base_query =
      case content_type do
        "timeline" ->
          from m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: m.conversation_id == c.id,
            where: c.type == "timeline",
            where: is_nil(m.deleted_at)

        "discussions" ->
          from m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: m.conversation_id == c.id,
            where: c.type == "community",
            where: is_nil(m.deleted_at)

        "chat" ->
          from m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: m.conversation_id == c.id,
            where: c.type in ["group", "dm", "channel"],
            where: is_nil(m.deleted_at)

        _ ->
          from m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: m.conversation_id == c.id,
            where: c.type == "timeline",
            where: is_nil(m.deleted_at)
      end

    # Add search filter if provided
    query =
      if search_query != "" do
        search_pattern = "%#{search_query}%"

        from [m, c] in base_query,
          join: u in Accounts.User,
          on: m.sender_id == u.id,
          where:
            ilike(m.content, ^search_pattern) or
              ilike(u.username, ^search_pattern) or
              ilike(u.handle, ^search_pattern) or
              ilike(c.name, ^search_pattern)
      else
        base_query
      end

    # Get content
    content =
      query
      |> order_by([m], desc: m.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload([:sender, conversation: []])
      |> Repo.all()
      |> Elektrine.Messaging.Message.decrypt_messages()

    # Get counts for all types
    counts = %{
      timeline:
        from(m in Elektrine.Messaging.Message,
          join: c in Elektrine.Messaging.Conversation,
          on: m.conversation_id == c.id,
          where: c.type == "timeline" and is_nil(m.deleted_at)
        )
        |> Repo.aggregate(:count),
      discussions:
        from(m in Elektrine.Messaging.Message,
          join: c in Elektrine.Messaging.Conversation,
          on: m.conversation_id == c.id,
          where: c.type == "community" and is_nil(m.deleted_at)
        )
        |> Repo.aggregate(:count),
      chat:
        from(m in Elektrine.Messaging.Message,
          join: c in Elektrine.Messaging.Conversation,
          on: m.conversation_id == c.id,
          where: c.type in ["group", "dm", "channel"] and is_nil(m.deleted_at)
        )
        |> Repo.aggregate(:count)
    }

    total_count = query |> Repo.aggregate(:count)
    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    current_user = conn.assigns.current_user
    timezone = current_user.timezone || "Etc/UTC"
    time_format = current_user.time_format || "12h"

    render(conn, :content_moderation,
      content: content,
      content_type: content_type,
      search_query: search_query,
      counts: counts,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range,
      timezone: timezone,
      time_format: time_format
    )
  end

  def delete_content(conn, %{"content_id" => content_id, "type" => content_type}) do
    message = Repo.get!(Elektrine.Messaging.Message, content_id)

    message
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update!()

    content_name =
      case content_type do
        "timeline" -> "Timeline post"
        "discussions" -> "Discussion post"
        "chat" -> "Chat message"
        _ -> "Content"
      end

    conn
    |> put_flash(:info, "#{content_name} deleted successfully.")
    |> redirect(to: ~p"/pripyat/content-moderation?type=#{content_type}")
  end

  def unsubscribe_stats(conn, params) do
    alias Elektrine.Email.ListTypes
    alias Elektrine.Email.Unsubscribes

    page = SafeConvert.parse_page(params)
    per_page = 50

    # Get all unsubscribes with pagination
    query =
      from u in Elektrine.Email.Unsubscribe,
        order_by: [desc: u.unsubscribed_at],
        limit: ^per_page,
        offset: ^((page - 1) * per_page)

    unsubscribes = Repo.all(query)
    total_count = Repo.aggregate(Elektrine.Email.Unsubscribe, :count)
    total_pages = ceil(total_count / per_page)

    # Get statistics
    stats = Unsubscribes.stats()

    # Get counts per list
    list_counts =
      from(u in Elektrine.Email.Unsubscribe,
        group_by: u.list_id,
        select: {u.list_id, count(u.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {list_id, count} ->
        %{
          list_id: list_id || "general",
          list_name: ListTypes.get_name(list_id || "elektrine-general"),
          count: count
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)

    render(conn, :unsubscribe_stats,
      unsubscribes: unsubscribes,
      stats: stats,
      list_counts: list_counts,
      page: page,
      total_pages: total_pages,
      total_count: total_count
    )
  end

  # Helper for pagination
  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..max(total_pages, 1) |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        Enum.to_list(1..5) ++ [:gap, total_pages]

      current_page >= total_pages - 3 ->
        [1, :gap] ++ Enum.to_list((total_pages - 4)..total_pages)

      true ->
        [1, :gap] ++ Enum.to_list((current_page - 1)..(current_page + 1)) ++ [:gap, total_pages]
    end
  end
end
