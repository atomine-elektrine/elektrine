defmodule ElektrineWeb.ChatLive.Bootstrap do
  @moduledoc false

  alias ElektrineWeb.ChatLive.Operations.Helpers
  alias ElektrineWeb.ChatLive.State

  def initialize_socket(socket, opts) do
    cached_conversations = Keyword.fetch!(opts, :cached_conversations)
    cached_unread = Keyword.fetch!(opts, :cached_unread)
    cached_servers = Keyword.fetch!(opts, :cached_servers)
    chat_attachment_limit = Keyword.fetch!(opts, :chat_attachment_limit)
    user_token = Keyword.fetch!(opts, :user_token)
    custom_emojis = Keyword.fetch!(opts, :custom_emojis)
    federation_preview = Keyword.fetch!(opts, :federation_preview)
    loading_conversations = Keyword.fetch!(opts, :loading_conversations)

    filtered_cached_conversations =
      Helpers.scope_conversations_to_server(cached_conversations, nil)

    socket
    |> Phoenix.Component.assign(:page_title, "Chat")
    |> Phoenix.Component.assign(:ui, %State.UI{})
    |> Phoenix.Component.assign(:search, %State.Search{user_results: []})
    |> Phoenix.Component.assign(:call, %State.Call{})
    |> Phoenix.Component.assign(:form, %State.Form{})
    |> Phoenix.Component.assign(:context_menu, %State.ContextMenu{})
    |> Phoenix.Component.assign(:message, %State.Message{})
    |> Phoenix.Component.assign(
      :conversation,
      %State.Conversation{
        list: cached_conversations,
        selected: nil,
        filtered: filtered_cached_conversations,
        last_message_read_status: %{},
        unread_count: cached_unread,
        unread_counts: %{}
      }
    )
    |> Phoenix.Component.assign(:joined_servers, cached_servers)
    |> Phoenix.Component.assign(:active_server_id, nil)
    |> Phoenix.Component.assign(:moderation, %State.Moderation{})
    |> Phoenix.Component.assign(:browse, %State.Browse{})
    |> Phoenix.Component.assign(:profile, %State.Profile{})
    |> Phoenix.Component.assign(:messages, [])
    |> Phoenix.Component.assign(:uploaded_files, [])
    |> Phoenix.Component.assign(:can_send_messages, true)
    |> Phoenix.LiveView.allow_upload(:chat_attachments,
      accept: ~w(.jpg .jpeg .png .gif .webp .heic .heif .avif .pdf .doc .docx .xls .xlsx .txt),
      max_entries: 5,
      max_file_size: chat_attachment_limit
    )
    |> Phoenix.LiveView.allow_upload(:server_icon_upload,
      accept: ~w(.jpg .jpeg .png .gif .webp),
      max_entries: 1,
      max_file_size: 5 * 1024 * 1024
    )
    |> Phoenix.LiveView.allow_upload(:group_avatar_upload,
      accept: ~w(.jpg .jpeg .png .gif .webp),
      max_entries: 1,
      max_file_size: 5 * 1024 * 1024
    )
    |> Phoenix.LiveView.allow_upload(:channel_avatar_upload,
      accept: ~w(.jpg .jpeg .png .gif .webp),
      max_entries: 1,
      max_file_size: 5 * 1024 * 1024
    )
    |> Phoenix.Component.assign(:user_token, user_token)
    |> Phoenix.Component.assign(:show_mobile_search, false)
    |> Phoenix.Component.assign(:show_report_modal, false)
    |> Phoenix.Component.assign(:report_type, nil)
    |> Phoenix.Component.assign(:report_id, nil)
    |> Phoenix.Component.assign(:report_metadata, %{})
    |> Phoenix.Component.assign(:user_communities, [])
    |> Phoenix.Component.assign(:has_more_older_messages, false)
    |> Phoenix.Component.assign(:has_more_newer_messages, false)
    |> Phoenix.Component.assign(:oldest_message_id, nil)
    |> Phoenix.Component.assign(:processed_call_events, MapSet.new())
    |> Phoenix.Component.assign(:newest_message_id, nil)
    |> Phoenix.Component.assign(:loading_older_messages, false)
    |> Phoenix.Component.assign(:loading_newer_messages, false)
    |> Phoenix.Component.assign(:initial_messages_loading, false)
    |> Phoenix.Component.assign(:first_unread_message_id, nil)
    |> Phoenix.Component.assign(:show_image_modal, false)
    |> Phoenix.Component.assign(:modal_image_url, nil)
    |> Phoenix.Component.assign(:modal_images, [])
    |> Phoenix.Component.assign(:modal_image_index, 0)
    |> Phoenix.Component.assign(:modal_post, nil)
    |> Phoenix.Component.assign(:public_server_search_results, [])
    |> Phoenix.Component.assign(:public_group_search_results, [])
    |> Phoenix.Component.assign(:public_channel_search_results, [])
    |> Phoenix.Component.assign(:custom_emojis, custom_emojis)
    |> Phoenix.Component.assign(:federation_preview, federation_preview)
    |> Phoenix.Component.assign(:federation_presence, %{})
    |> Phoenix.Component.assign(:room_presence_timer_ref, nil)
    |> Phoenix.Component.assign(:pending_remote_join_requests, [])
    |> Phoenix.Component.assign(:loading_conversations, loading_conversations)
    |> Phoenix.Component.assign(:refresh_conversations_scheduled, false)
  end
end
