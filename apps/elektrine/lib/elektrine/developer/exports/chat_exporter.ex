defmodule Elektrine.Developer.Exports.ChatExporter do
  @moduledoc """
  Exports user's chat messages from DMs, groups, and channels.

  Supported formats:
  - json: JSON format (most complete)
  - csv: CSV format for spreadsheet import
  """

  import Ecto.Query
  alias Elektrine.Messaging.{ChatMessage, Conversation, ConversationMember}
  alias Elektrine.Repo

  @doc """
  Exports all chat data for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export(user_id, file_path, format, filters \\ %{}) do
    conversations = fetch_conversations(user_id)
    messages = fetch_messages(user_id, filters)

    count = length(messages)

    data = %{
      conversations: Enum.map(conversations, &format_conversation/1),
      messages: Enum.map(messages, &format_message/1)
    }

    case format do
      "json" -> export_json(data, file_path)
      "csv" -> export_csv(data, file_path)
      _ -> export_json(data, file_path)
    end

    {:ok, count}
  end

  defp fetch_conversations(user_id) do
    # First get conversation IDs user is member of
    conversation_ids =
      from(cm in ConversationMember,
        where: cm.user_id == ^user_id,
        select: cm.conversation_id
      )
      |> Repo.all()

    # Then fetch conversations with preloads
    from(c in Conversation,
      where: c.id in ^conversation_ids,
      where: c.type in ["dm", "group", "channel"],
      preload: [:members]
    )
    |> Repo.all()
  end

  defp fetch_messages(user_id, filters) do
    # Get conversation IDs user is member of
    conversation_ids =
      from(cm in ConversationMember,
        where: cm.user_id == ^user_id,
        select: cm.conversation_id
      )
      |> Repo.all()

    query =
      from m in ChatMessage,
        where: m.conversation_id in ^conversation_ids,
        where: is_nil(m.deleted_at),
        order_by: [asc: m.inserted_at],
        preload: [:sender, :conversation]

    query = apply_filters(query, filters)

    Repo.all(query)
  end

  defp apply_filters(query, %{"from_date" => from_date}) when is_binary(from_date) do
    case DateTime.from_iso8601(from_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, %{"to_date" => to_date}) when is_binary(to_date) do
    case DateTime.from_iso8601(to_date) do
      {:ok, dt, _} -> from(m in query, where: m.inserted_at <= ^dt)
      _ -> query
    end
  end

  defp apply_filters(query, _), do: query

  defp export_json(data, file_path) do
    json = Jason.encode!(data, pretty: true)
    File.write!(file_path, json)
  end

  defp export_csv(data, file_path) do
    csv_content = messages_to_csv(data.messages)
    File.write!(file_path, csv_content)
  end

  defp messages_to_csv(messages) do
    headers = ["id", "conversation_id", "sender", "content", "type", "created_at"]
    header_row = Enum.join(headers, ",")

    rows =
      messages
      |> Enum.map(fn msg ->
        [
          to_string(msg.id),
          to_string(msg.conversation_id),
          escape_csv(msg.sender || ""),
          escape_csv(msg.content || ""),
          msg.message_type,
          to_string(msg.created_at)
        ]
        |> Enum.join(",")
      end)

    [header_row | rows] |> Enum.join("\n")
  end

  defp escape_csv(string) when is_binary(string) do
    if String.contains?(string, [",", "\"", "\n"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end

  defp escape_csv(_), do: ""

  defp format_conversation(conversation) do
    members =
      case conversation.members do
        members when is_list(members) ->
          Enum.map(members, fn m ->
            %{
              user_id: m.user_id,
              role: m.role,
              joined_at: m.inserted_at
            }
          end)

        _ ->
          []
      end

    %{
      id: conversation.id,
      type: conversation.type,
      name: conversation.name,
      description: conversation.description,
      members: members,
      created_at: conversation.inserted_at
    }
  end

  defp format_message(message) do
    sender_name =
      if message.sender do
        message.sender.username || message.sender.handle
      else
        nil
      end

    conversation_name =
      if message.conversation do
        message.conversation.name
      else
        nil
      end

    %{
      id: message.id,
      conversation_id: message.conversation_id,
      conversation_name: conversation_name,
      sender_id: message.sender_id,
      sender: sender_name,
      content: message.content,
      message_type: message.message_type,
      media_urls: message.media_urls,
      reply_to_id: message.reply_to_id,
      created_at: message.inserted_at,
      edited_at: message.edited_at
    }
  end
end
