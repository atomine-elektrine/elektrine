defmodule ElektrineChatWeb.ChatLive.Operations.Helpers do
  @moduledoc """
  Helper functions for ChatLive module.
  Contains utility functions for formatting, filtering, and calculating various states.
  """

  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Social.{Conversation, Message}

  @doc """
  Get the display name for a conversation based on the current user.
  """
  def conversation_name(conversation, current_user_id) do
    Conversation.display_name(conversation, current_user_id)
  end

  @doc """
  Format reactions for display, grouping by emoji.
  """
  def format_reactions(%Ecto.Association.NotLoaded{}), do: []

  def format_reactions(reactions) when is_list(reactions) do
    reactions
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, grouped_reactions} ->
      users = Enum.map(grouped_reactions, &reaction_actor_label/1)
      {emoji, length(grouped_reactions), users}
    end)
  end

  def format_reactions(_), do: []

  @doc """
  Removes duplicate messages while preserving the first occurrence order.
  """
  def dedupe_messages(messages) when is_list(messages) do
    Enum.uniq_by(messages, & &1.id)
  end

  def dedupe_messages(_), do: []

  @doc """
  Check if a specific user reacted to a message with a specific emoji.
  """
  def user_reacted?(%Ecto.Association.NotLoaded{}, _emoji, _user_id), do: false

  def user_reacted?(reactions, emoji, user_id) when is_list(reactions) do
    Enum.any?(reactions, fn reaction ->
      reaction.emoji == emoji and reaction.user_id == user_id
    end)
  end

  def user_reacted?(_, _emoji, _user_id), do: false

  @doc """
  Filter conversations based on search query.
  Searches by conversation name, last message content, and member usernames.
  """
  def filter_conversations(conversations, query, current_user_id) do
    search_term = String.downcase(String.trim(query))

    Enum.filter(conversations, fn conversation ->
      # Search by conversation name
      name_match =
        conversation
        |> conversation_name(current_user_id)
        |> String.downcase()
        |> String.contains?(search_term)

      # Search by last message content
      message_match =
        case conversation.messages do
          [last_message | _] ->
            last_message
            |> message_display_content()
            |> String.downcase()
            |> String.contains?(search_term)

          [] ->
            false
        end

      # Search by member usernames (for groups/channels)
      member_match =
        if conversation.type != "dm" do
          Enum.any?(conversation.members || [], fn member ->
            if member.left_at == nil and member.user do
              username_match =
                (member.user.handle || member.user.username)
                |> String.downcase()
                |> String.contains?(search_term)

              display_name_match =
                if member.user.display_name do
                  member.user.display_name
                  |> String.downcase()
                  |> String.contains?(search_term)
                else
                  false
                end

              username_match or display_name_match
            else
              false
            end
          end)
        else
          false
        end

      name_match or message_match or member_match
    end)
  end

  @doc """
  Scope visible channel conversations to the currently selected server.
  DMs and group conversations stay visible across servers.
  """
  def scope_conversations_to_server(conversations, active_server_id)
      when is_list(conversations) do
    case active_server_id do
      server_id when is_integer(server_id) ->
        Enum.filter(conversations, fn conversation ->
          conversation.type != "channel" or is_nil(conversation.server_id) or
            conversation.server_id == server_id
        end)

      _ ->
        Enum.filter(conversations, fn conversation ->
          conversation.type != "channel" or is_nil(conversation.server_id)
        end)
    end
  end

  def scope_conversations_to_server(_conversations, _active_server_id), do: []

  @doc """
  Load timeout status for multiple users in a conversation.
  Returns a map of user_id => is_timed_out (boolean).

  Uses batch query for efficiency (single DB query instead of N queries).
  """
  def load_timeout_status(user_ids, conversation_id) do
    Elektrine.Messaging.Moderation.users_timed_out(user_ids, conversation_id)
  end

  @doc """
  Check if user is admin of a specific conversation.
  System admins can moderate any conversation.
  """
  def conversation_admin?(conversation, user) do
    cond do
      # No user or conversation
      is_nil(user) or is_nil(conversation) ->
        false

      # System admins can moderate any conversation
      user.is_admin ->
        true

      # Check if user is conversation admin
      conversation.members != nil ->
        member =
          Enum.find(conversation.members, fn m ->
            m.user_id == user.id && is_nil(m.left_at)
          end)

        not is_nil(member) and member.role == "admin"

      # Default case
      true ->
        false
    end
  end

  @doc """
  Check if user is admin of the current conversation (for event handlers).
  Accepts a socket and checks the selected_conversation assign.
  """
  def conversation_admin_socket?(socket) do
    conversation = Map.get(socket.assigns, :selected_conversation)
    current_user = Map.get(socket.assigns, :current_user)
    conversation_admin?(conversation, current_user)
  end

  @doc """
  Format duration in seconds to human readable string.
  """
  def format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds} seconds"
      seconds < 3600 -> "#{div(seconds, 60)} minutes"
      seconds < 86_400 -> "#{div(seconds, 3600)} hours"
      true -> "#{div(seconds, 86400)} days"
    end
  end

  def format_duration(_), do: ""

  @doc """
  Popular emoji list for emoji picker.
  """
  def popular_emojis do
    [
      "😀",
      "😃",
      "😄",
      "😁",
      "😆",
      "😅",
      "😂",
      "🤣",
      "😊",
      "😇",
      "🙂",
      "🙃",
      "😉",
      "😌",
      "😍",
      "🥰",
      "😘",
      "😗",
      "😙",
      "😚",
      "😋",
      "😛",
      "😝",
      "😜",
      "🤪",
      "🤨",
      "🧐",
      "🤓",
      "😎",
      "🤩",
      "🥳",
      "😏",
      "😒",
      "😞",
      "😔",
      "😟",
      "😕",
      "🙁",
      "☹️",
      "😣",
      "😖",
      "😫",
      "😩",
      "🥺",
      "😢",
      "😭",
      "😤",
      "😠",
      "😡",
      "🤬",
      "🤯",
      "😳",
      "🥵",
      "🥶",
      "😱",
      "😨",
      "😰",
      "😥",
      "😓",
      "🤗",
      "🤔",
      "🤭",
      "🤫",
      "🤥",
      "😶",
      "😐",
      "😑",
      "😬",
      "🙄",
      "😯",
      "👍",
      "👎",
      "👌",
      "✌️",
      "🤞",
      "🤟",
      "🤘",
      "🤙",
      "👈",
      "👉",
      "👆",
      "🖕",
      "👇",
      "☝️",
      "👋",
      "🤚",
      "🖐",
      "✋",
      "🖖",
      "👏",
      "🙌",
      "🤲",
      "🙏",
      "✍️",
      "💪",
      "🦾",
      "🦿",
      "🦵",
      "🦶",
      "👂",
      "❤️",
      "🧡",
      "💛",
      "💚",
      "💙",
      "💜",
      "🖤",
      "🤍",
      "🤎",
      "💔",
      "❣️",
      "💕",
      "💞",
      "💓",
      "💗",
      "💖",
      "💘",
      "💝",
      "💟",
      "☮️",
      "🔥",
      "⭐",
      "🌟",
      "✨",
      "⚡",
      "☄️",
      "💥",
      "💯",
      "💢",
      "💨"
    ]
  end

  @doc """
  Find the first unread message in a conversation for a user.
  Used for scroll positioning.

  Optimized to use a single database query for member data.
  """
  def find_first_unread_message(messages, conversation_id, user_id) do
    # Early exit if no messages
    if Enum.empty?(messages) do
      nil
    else
      # Single query to get member data with last read info
      member = Messaging.get_conversation_member(conversation_id, user_id)

      case member do
        nil ->
          # User is not a member
          nil

        %{last_read_message_id: last_id} when not is_nil(last_id) ->
          # User has a last read message ID
          find_first_unread_by_message_id(messages, last_id, user_id, member.last_read_at)

        %{last_read_at: last_read_at} when not is_nil(last_read_at) ->
          # User has a last read timestamp but no message ID
          find_first_unread_by_timestamp(messages, last_read_at, user_id)

        _ ->
          # User has never read any messages, find first message from other users
          find_first_message_from_others(messages, user_id)
      end
    end
  end

  # Find first unread message after a known last-read message ID
  defp find_first_unread_by_message_id(messages, last_id, user_id, last_read_at) do
    last_read_index = Enum.find_index(messages, fn msg -> msg.id == last_id end)

    case last_read_index do
      nil ->
        # Last read message not in current list, fall back to timestamp
        if last_read_at do
          find_first_unread_by_timestamp(messages, last_read_at, user_id)
        else
          find_first_message_from_others(messages, user_id)
        end

      index ->
        # Find the next message after the last read one from other users
        messages
        |> Enum.drop(index + 1)
        |> Enum.find(fn message -> message.sender_id != user_id end)
        |> case do
          nil -> nil
          message -> message.id
        end
    end
  end

  # Find first message after a timestamp from other users
  defp find_first_unread_by_timestamp(messages, last_read_at, user_id) do
    cutoff = to_naive_datetime(last_read_at)

    messages
    |> Enum.find(fn message ->
      message.sender_id != user_id &&
        compare_message_time(message.inserted_at, cutoff) == :gt
    end)
    |> case do
      nil -> nil
      message -> message.id
    end
  end

  # Find the first message from any other user
  defp find_first_message_from_others(messages, user_id) do
    messages
    |> Enum.find(fn message -> message.sender_id != user_id end)
    |> case do
      nil -> nil
      message -> message.id
    end
  end

  defp reaction_actor_label(reaction) do
    cond do
      is_map(reaction.user) and not match?(%Ecto.Association.NotLoaded{}, reaction.user) ->
        reaction.user.handle || reaction.user.username || "user"

      is_map(reaction.remote_actor) and
          not match?(%Ecto.Association.NotLoaded{}, reaction.remote_actor) ->
        username = reaction.remote_actor.username || "remote"
        domain = reaction.remote_actor.domain

        if is_binary(domain) and domain != "" do
          "#{username}@#{domain}"
        else
          username
        end

      true ->
        "user"
    end
  end

  defp message_display_content(%Message{} = message), do: Message.display_content(message)
  defp message_display_content(%ChatMessage{} = message), do: ChatMessage.display_content(message)

  defp message_display_content(message) when is_map(message) do
    content =
      message
      |> map_message_value(:content)
      |> fallback_message_text(message)
      |> normalize_message_text()

    if content != "", do: content, else: fallback_message_label(message)
  end

  defp message_display_content(_), do: ""

  defp fallback_message_text(nil, message), do: map_message_value(message, :body)
  defp fallback_message_text("", message), do: map_message_value(message, :body)
  defp fallback_message_text(content, _message), do: content

  defp fallback_message_label(message) do
    message_type = map_message_value(message, :message_type)
    media_urls = map_message_value(message, :media_urls) || []

    cond do
      message_type == "voice" ->
        "Voice message"

      message_type == "image" ->
        "Photo"

      message_type == "file" ->
        "File"

      message_type == "system" ->
        "[System message]"

      is_list(media_urls) and media_urls != [] ->
        "[Attachment]"

      true ->
        ""
    end
  end

  defp normalize_message_text(nil), do: ""

  defp normalize_message_text(text) when is_binary(text) do
    text
    |> String.trim()
  end

  defp normalize_message_text(text) when is_atom(text), do: Atom.to_string(text)
  defp normalize_message_text(text) when is_integer(text), do: Integer.to_string(text)
  defp normalize_message_text(text) when is_float(text), do: Float.to_string(text)
  defp normalize_message_text(_), do: ""

  defp map_message_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp compare_message_time(_message_time, nil), do: :lt

  defp compare_message_time(%NaiveDateTime{} = message_time, %NaiveDateTime{} = cutoff) do
    NaiveDateTime.compare(message_time, cutoff)
  end

  defp compare_message_time(%DateTime{} = message_time, %NaiveDateTime{} = cutoff) do
    message_time
    |> DateTime.to_naive()
    |> NaiveDateTime.compare(cutoff)
  end

  defp compare_message_time(_message_time, _cutoff), do: :lt

  defp to_naive_datetime(%NaiveDateTime{} = datetime), do: datetime
  defp to_naive_datetime(%DateTime{} = datetime), do: DateTime.to_naive(datetime)
  defp to_naive_datetime(_), do: nil

  @doc """
  Calculate unread counts for each conversation using a single batch query.
  Returns a map of conversation_id => unread_count.
  """
  def calculate_unread_counts(conversations, user_id) do
    conversation_ids = Enum.map(conversations, & &1.id)
    Messaging.get_conversation_unread_counts(conversation_ids, user_id)
  end

  @doc """
  Sort conversations: pinned first, then unread, then by last activity.
  """
  def sort_conversations_by_unread(conversations, unread_counts, user_id) do
    Enum.sort(conversations, fn conv1, conv2 ->
      # Check if conversation is pinned for this user
      pinned1 =
        Enum.find(conv1.members, fn m -> m.user_id == user_id end)
        |> then(fn m -> m && m.pinned end) || false

      pinned2 =
        Enum.find(conv2.members, fn m -> m.user_id == user_id end)
        |> then(fn m -> m && m.pinned end) || false

      unread1 = Map.get(unread_counts, conv1.id, 0) > 0
      unread2 = Map.get(unread_counts, conv2.id, 0) > 0

      cond do
        # Pinned conversations always come first
        pinned1 != pinned2 ->
          pinned1

        # Among pinned or unpinned, unread comes first
        unread1 != unread2 ->
          unread1

        # Same pinned and unread status - sort by last message time
        true ->
          NaiveDateTime.compare(
            conv1.last_message_at || conv1.updated_at,
            conv2.last_message_at || conv2.updated_at
          ) == :gt
      end
    end)
  end

  @doc """
  Calculate read status for the last message in each conversation using a single batch query.
  Returns a map of conversation_id => %{is_read: boolean, reader_count: integer}.
  """
  def calculate_last_message_read_status(conversations, user_id) do
    # Collect all messages where current user is the sender
    message_info_list =
      conversations
      |> Enum.flat_map(fn conversation ->
        case conversation.messages do
          [last_message | _]
          when not is_nil(last_message.sender_id) and last_message.sender_id == user_id ->
            [{conversation.id, last_message.id, last_message.inserted_at}]

          _ ->
            []
        end
      end)

    # Batch query for all read statuses
    Messaging.get_batch_last_message_read_status(message_info_list)
  end

  @doc """
  Filter conversations to remove DMs with a specific blocked user.
  """
  def filter_blocked_conversations(conversations, _current_user_id, blocked_user_id) do
    Enum.filter(conversations, fn conversation ->
      case conversation.type do
        "dm" ->
          # Check if this DM is with the blocked user
          not Enum.any?(conversation.members, fn member ->
            member.user_id == blocked_user_id and is_nil(member.left_at)
          end)

        _ ->
          # Keep all non-DM conversations
          true
      end
    end)
  end

  @doc """
  Get user's communities for discussion creation.
  """
  def get_user_communities(user_id) do
    Messaging.list_chat_conversations(user_id)
    |> Enum.filter(&(&1.type == "community"))
  end

  @doc """
  Formats a timestamp for conversation list display.
  Shows time only for today, date + time for older messages.
  """
  def format_conversation_time(nil), do: ""

  def format_conversation_time(datetime) do
    now = DateTime.utc_now()
    # Convert NaiveDateTime to DateTime if needed
    datetime_utc =
      case datetime do
        %DateTime{} -> DateTime.shift_zone!(datetime, "Etc/UTC")
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
      end

    today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    yesterday_start = DateTime.add(today_start, -1, :day)

    cond do
      DateTime.compare(datetime_utc, today_start) in [:eq, :gt] ->
        # Today - show time only
        Calendar.strftime(datetime, "%H:%M")

      DateTime.compare(datetime_utc, yesterday_start) in [:eq, :gt] ->
        # Yesterday
        "Yesterday"

      DateTime.diff(now, datetime_utc, :day) <= 7 ->
        # Within last week - show day name
        Calendar.strftime(datetime, "%a")

      DateTime.diff(now, datetime_utc, :day) <= 365 ->
        # Within last year - show month and day
        Calendar.strftime(datetime, "%b %d")

      true ->
        # Older than a year - show full date
        Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  @doc """
  Convert URLs in text to clickable links.
  """
  def linkify_urls(text) when is_binary(text) do
    url_pattern = ~r/(https?:\/\/[^\s&<>]+)/

    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> then(fn escaped_text ->
      Regex.replace(url_pattern, escaped_text, fn _, url ->
        # Remove trailing punctuation that might not be part of the URL
        clean_url = String.replace(url, ~r/[.!?,;:]$/, "")
        # URL is already escaped, just use it directly
        # Use underline and opacity for better contrast in chat bubbles
        "<a href=\"#{clean_url}\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"underline underline-offset-2 opacity-90 hover:opacity-100 font-medium\">#{clean_url}</a>"
      end)
    end)
  end

  def linkify_urls(text), do: text

  @doc """
  Generate Phoenix Token for user authentication in channels.
  """
  def generate_user_token(user_id) do
    user = Elektrine.Accounts.get_user!(user_id)

    Phoenix.Token.sign(ElektrineWeb.Endpoint, "user socket", %{
      "user_id" => user.id,
      "password_changed_at" => password_changed_at_unix(user),
      "auth_valid_after" => auth_valid_after_unix(user)
    })
  end

  @doc """
  Renders message content with custom emojis replaced by HTML img tags.
  Returns safe HTML string.
  """
  def render_message_content(nil), do: nil

  def render_message_content(content) when is_binary(content) do
    # First escape HTML to prevent XSS
    escaped_content = Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()

    # Then replace emoji shortcodes with img tags
    {processed_content, _emojis} = Elektrine.Emojis.render_custom_emojis(escaped_content)

    # Return as safe HTML
    Phoenix.HTML.raw(processed_content)
  end

  def render_message_content(content), do: content

  defp password_changed_at_unix(user) do
    case user.last_password_change do
      %DateTime{} = changed_at -> DateTime.to_unix(changed_at, :second)
      _ -> 0
    end
  end

  defp auth_valid_after_unix(user) do
    case user.auth_valid_after do
      %DateTime{} = valid_after -> DateTime.to_unix(valid_after, :second)
      _ -> 0
    end
  end
end
