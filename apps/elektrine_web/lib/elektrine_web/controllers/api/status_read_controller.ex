defmodule ElektrineWeb.API.StatusReadController do
  @moduledoc """
  API endpoints for reading timeline statuses and status context.
  """
  use ElektrineWeb, :controller

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.API.StatusJSON

  action_fallback ElektrineWeb.FallbackController

  @max_context_depth 50
  @max_account_list 80
  @max_status_list 80

  def index(conn, params) do
    user = conn.assigns[:current_user]
    ids = status_ids(params)
    statuses_by_id = get_visible_statuses(ids, user.id, status_read_opts(params))

    statuses =
      ids
      |> Enum.map(&Map.get(statuses_by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&format_status(&1, user.id))

    json(conn, statuses)
  end

  def show(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id, status_read_opts(params)) do
      %Message{} = status -> json(conn, format_status(status, user.id))
      nil -> not_found(conn)
    end
  end

  def context(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{} = status ->
        ancestors = collect_ancestors(status.reply_to_id, user.id, [], @max_context_depth)
        descendants = collect_descendants([status.id], user.id, @max_context_depth)

        json(conn, %{
          ancestors: Enum.map(ancestors, &format_status(&1, user.id)),
          descendants: Enum.map(descendants, &format_status(&1, user.id))
        })

      nil ->
        not_found(conn)
    end
  end

  def favourited_by(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{} = status ->
        accounts =
          social().status_liked_by_accounts(status.id, @max_account_list)

        json(conn, AccountJSON.format_accounts(accounts, user.id))

      nil ->
        not_found(conn)
    end
  end

  def reblogged_by(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{} = status ->
        accounts =
          social().status_boosted_by_accounts(status.id, @max_account_list)

        json(conn, AccountJSON.format_accounts(accounts, user.id))

      nil ->
        not_found(conn)
    end
  end

  def quotes(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{} = status ->
        quotes =
          social().list_status_quotes(status.id, user.id, quote_opts(params))
          |> Enum.map(&Message.decrypt_content/1)
          |> Enum.map(&format_status(&1, user.id))

        json(conn, quotes)

      nil ->
        not_found(conn)
    end
  end

  def source(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{sender_id: sender_id} = status when sender_id == user.id ->
        json(conn, %{
          id: to_string(status.id),
          text: status.content || "",
          spoiler_text: status.content_warning || ""
        })

      _ ->
        not_found(conn)
    end
  end

  def history(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_visible_status(id, user.id) do
      %Message{} = status ->
        json(conn, format_history(status, user.id))

      nil ->
        not_found(conn)
    end
  end

  defp collect_ancestors(nil, _viewer_id, ancestors, _depth), do: ancestors
  defp collect_ancestors(_reply_to_id, _viewer_id, ancestors, 0), do: ancestors

  defp collect_ancestors(reply_to_id, viewer_id, ancestors, depth) do
    case get_visible_status(reply_to_id, viewer_id) do
      %Message{} = parent ->
        collect_ancestors(parent.reply_to_id, viewer_id, [parent | ancestors], depth - 1)

      nil ->
        ancestors
    end
  end

  defp collect_descendants([], _viewer_id, _depth), do: []
  defp collect_descendants(_parent_ids, _viewer_id, 0), do: []

  defp collect_descendants(parent_ids, viewer_id, depth) do
    preloads = status_preloads()

    replies =
      from(message in Message,
        where:
          message.reply_to_id in ^parent_ids and
            message.is_draft != true and
            is_nil(message.deleted_at) and
            (message.approval_status == "approved" or is_nil(message.approval_status)),
        order_by: [asc: message.inserted_at, asc: message.id],
        preload: ^preloads
      )
      |> Repo.all()
      |> Enum.filter(&social().status_visible?(viewer_id, &1))
      |> Enum.map(&Message.decrypt_content/1)

    nested = collect_descendants(Enum.map(replies, & &1.id), viewer_id, depth - 1)
    replies ++ nested
  end

  defp get_visible_status(id, viewer_id, opts \\ []) do
    with %Message{} = status <- get_status(id),
         true <- social().status_explicit_visible?(viewer_id, status, opts) do
      status
    else
      _ -> nil
    end
  end

  defp get_visible_statuses(ids, viewer_id, opts)

  defp get_visible_statuses([], _viewer_id, _opts), do: %{}

  defp get_visible_statuses(ids, viewer_id, opts) do
    preloads = status_preloads()

    statuses =
      Message
      |> where([message], message.id in ^ids)
      |> preload(^preloads)
      |> Repo.all()
      |> Enum.map(&Message.decrypt_content/1)

    statuses
    |> then(&social().filter_explicit_visible_statuses(viewer_id, &1, opts))
    |> Map.new(&{&1.id, &1})
  end

  defp get_status(id) do
    Message
    |> Repo.get(id)
    |> case do
      %Message{} = status ->
        status
        |> Repo.preload(status_preloads())
        |> Message.decrypt_content()

      nil ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp format_status(%Message{} = status, viewer_id) do
    StatusJSON.format_statuses([status], viewer_id)
    |> List.first()
  end

  defp format_history(%Message{} = status, viewer_id) do
    status
    |> former_representations()
    |> Enum.map(&format_history_entry(&1, status, viewer_id))
    |> Kernel.++([format_current_history_entry(status, viewer_id)])
  end

  defp former_representations(%Message{media_metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("formerRepresentations", %{})
    |> Map.get("orderedItems", [])
    |> case do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp former_representations(_status), do: []

  defp format_history_entry(item, status, viewer_id) when is_map(item) do
    %{
      content: Map.get(item, "content") || "",
      spoiler_text: Map.get(item, "summary") || "",
      sensitive: truthy?(Map.get(item, "sensitive")),
      created_at: parse_history_datetime(Map.get(item, "updated")) || status.inserted_at,
      account: AccountJSON.format_status_account(status, viewer_id)
    }
  end

  defp format_current_history_entry(%Message{} = status, viewer_id) do
    %{
      content: status.content || "",
      spoiler_text: status.content_warning || "",
      sensitive: status.sensitive || false,
      created_at: status.edited_at || status.updated_at || status.inserted_at,
      account: AccountJSON.format_status_account(status, viewer_id)
    }
  end

  defp quote_opts(params) do
    [
      limit: parse_limit(params["limit"]),
      before_id: params["max_id"],
      since_id: params["since_id"],
      min_id: params["min_id"]
    ]
  end

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_status_list)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> parse_limit(limit)
      _ -> 20
    end
  end

  defp parse_limit(_value), do: 20

  defp status_read_opts(params) do
    [with_muted: truthy?(params["with_muted"])]
  end

  defp status_ids(params) do
    params
    |> Map.take(["id", "id[]", :id])
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      value when is_integer(value) -> [value]
      _value -> []
    end)
    |> Enum.map(&parse_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_status_list)
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp parse_history_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_history_datetime(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp status_preloads, do: Messages.timeline_feed_preloads()
  defp social, do: Module.concat([Elektrine, Social])

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end
end
