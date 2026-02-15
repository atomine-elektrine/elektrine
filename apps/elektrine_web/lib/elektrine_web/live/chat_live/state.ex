defmodule ElektrineWeb.ChatLive.State do
  @moduledoc """
  State management structs for the Chat LiveView.

  This module defines structs to group related assigns and reduce assign bloat.
  """

  defmodule UI do
    @moduledoc """
    UI state including modal visibility and picker states.
    """
    defstruct show_new_chat: false,
              show_create_group: false,
              show_create_channel: false,
              show_group_modal: false,
              show_channel_modal: false,
              show_browse_channels: false,
              show_settings_modal: false,
              show_edit_modal: false,
              show_add_members_modal: false,
              show_message_search_modal: false,
              show_emoji_picker: false,
              show_gif_picker: false,
              show_profile_modal: false,
              show_member_management: false,
              show_moderation_log: false,
              show_browse_modal: false,
              show_incoming_call: false
  end

  defmodule Search do
    @moduledoc """
    Search-related state for users, messages, and GIFs.
    """
    defstruct query: "",
              results: [],
              conversation_query: "",
              message_query: "",
              message_results: [],
              gif_query: "",
              gif_results: [],
              browse_query: "",
              user_results: [],
              emoji_query: "",
              emoji_tab: "Smileys"
  end

  defmodule Call do
    @moduledoc """
    Voice/video call state.
    """
    defstruct active_call: nil,
              incoming_call: nil,
              audio_enabled: true,
              video_enabled: true,
              status: "connecting"
  end

  defmodule Form do
    @moduledoc """
    Form input state for group/channel creation and editing.
    """
    defstruct group_name: "",
              group_description: "",
              group_is_public: false,
              edit_name: "",
              edit_description: "",
              selected_users: []
  end

  defmodule ContextMenu do
    @moduledoc """
    Context menu state for conversations and messages.
    """
    defstruct conversation: nil,
              message: nil,
              position: %{x: 0, y: 0}
  end

  defmodule Message do
    @moduledoc """
    Message composition and display state.
    """
    defstruct new_message: "",
              reply_to: nil,
              uploaded_files: [],
              loading_messages: false,
              typing_users: [],
              read_status: %{},
              last_sent: nil,
              last_send_time: 0,
              last_signature: nil
  end

  defmodule Conversation do
    @moduledoc """
    Conversation list and selection state.
    """
    defstruct list: [],
              selected: nil,
              filtered: [],
              last_message_read_status: %{},
              unread_count: 0,
              unread_counts: %{}
  end

  defmodule Moderation do
    @moduledoc """
    Content moderation state.
    """
    defstruct log: [],
              user_timeout_status: %{}
  end

  defmodule Browse do
    @moduledoc """
    Browse channels/groups state.
    """
    defstruct tab: "channels",
              public_channels: [],
              public_groups: [],
              filtered_channels: [],
              filtered_groups: []
  end

  defmodule Profile do
    @moduledoc """
    User profile modal state.
    """
    defstruct user: nil
  end
end
