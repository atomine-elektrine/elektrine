defmodule Elektrine.Messaging.ChatMessage do
  @moduledoc """
  Schema for chat messages in DMs, groups, and channels.

  This is separate from the `messages` table which is used for timeline posts,
  community discussions, and ActivityPub federation.

  Chat messages are:
  - Encrypted for DMs (private conversations)
  - High-volume and ephemeral
  - Optimized for real-time delivery
  - Simple: text, images, files, voice, system messages
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :content, :string
    field :encrypted_content, :map
    field :search_index, {:array, :string}, default: []
    field :message_type, :string, default: "text"
    field :media_urls, {:array, :string}, default: []
    field :media_metadata, :map, default: %{}
    field :federated_source, :string
    field :origin_domain, :string
    field :is_federated_mirror, :boolean, default: false
    field :edited_at, :utc_datetime
    field :deleted_at, :utc_datetime

    # Voice message fields
    field :audio_duration, :integer
    field :audio_mime_type, :string

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :sender, Elektrine.Accounts.User
    belongs_to :reply_to, __MODULE__

    has_many :replies, __MODULE__, foreign_key: :reply_to_id
    has_many :reactions, Elektrine.Messaging.ChatMessageReaction, foreign_key: :chat_message_id

    timestamps()
  end

  @doc false
  def changeset(chat_message, attrs) do
    chat_message
    |> cast(attrs, [
      :conversation_id,
      :sender_id,
      :content,
      :encrypted_content,
      :search_index,
      :message_type,
      :media_urls,
      :media_metadata,
      :federated_source,
      :origin_domain,
      :is_federated_mirror,
      :reply_to_id,
      :edited_at,
      :deleted_at,
      :audio_duration,
      :audio_mime_type
    ])
    |> validate_required([:conversation_id])
    |> validate_inclusion(:message_type, ["text", "image", "file", "voice", "system"])
    |> validate_length(:content, max: 4000)
    |> validate_content_or_media()
    |> validate_content_security()
    |> validate_media_urls_security()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_id)
    |> foreign_key_constraint(:reply_to_id)
    |> unique_constraint(:federated_source,
      name: :chat_messages_conversation_federated_source_unique
    )
  end

  @doc """
  Creates a changeset for a text message.
  """
  def text_changeset(conversation_id, sender_id, content, reply_to_id \\ nil, encrypt? \\ true) do
    attrs =
      %{
        conversation_id: conversation_id,
        sender_id: sender_id,
        content: content,
        message_type: "text",
        reply_to_id: reply_to_id
      }
      |> maybe_encrypt(sender_id, encrypt?)

    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc """
  Creates a changeset for a media message (image or file).
  """
  def media_changeset(
        conversation_id,
        sender_id,
        media_urls,
        content \\ nil,
        media_metadata \\ %{},
        encrypt? \\ true
      ) do
    message_type = determine_media_type(media_urls)

    attrs =
      %{
        conversation_id: conversation_id,
        sender_id: sender_id,
        content: content,
        message_type: message_type,
        media_urls: media_urls,
        media_metadata: media_metadata
      }
      |> maybe_encrypt(sender_id, encrypt?)

    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc """
  Creates a changeset for a voice message.
  """
  def voice_changeset(conversation_id, sender_id, audio_url, duration, mime_type) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      message_type: "voice",
      media_urls: [audio_url],
      audio_duration: duration,
      audio_mime_type: mime_type
    })
  end

  @doc """
  Creates a changeset for a system message.
  """
  def system_changeset(conversation_id, content) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      content: content,
      message_type: "system"
    })
  end

  @doc """
  Creates a changeset for editing a message.
  """
  def edit_changeset(message, new_content, encrypt? \\ true) do
    attrs =
      %{
        content: new_content,
        edited_at: DateTime.utc_now()
      }
      |> maybe_encrypt(message.sender_id, encrypt?)

    message
    |> changeset(attrs)
  end

  @doc """
  Creates a changeset for soft-deleting a message.
  """
  def delete_changeset(message) do
    message
    |> changeset(%{deleted_at: DateTime.utc_now()})
  end

  @doc """
  Checks if the message is deleted.
  """
  def deleted?(%__MODULE__{deleted_at: nil}), do: false
  def deleted?(%__MODULE__{}), do: true

  @doc """
  Checks if the message has been edited.
  """
  def edited?(%__MODULE__{edited_at: nil}), do: false
  def edited?(%__MODULE__{}), do: true

  @doc """
  Returns the display content for the message.
  """
  def display_content(%__MODULE__{deleted_at: deleted_at}) when not is_nil(deleted_at) do
    "This message was deleted"
  end

  def display_content(%__MODULE__{content: content, message_type: "system"}) do
    content
  end

  def display_content(%__MODULE__{content: content, message_type: "text"}) do
    content
  end

  def display_content(%__MODULE__{
        content: content,
        message_type: "voice",
        audio_duration: duration
      }) do
    duration_str = format_duration(duration)

    if content && String.trim(content) != "" do
      "Voice message (#{duration_str}): #{content}"
    else
      "Voice message (#{duration_str})"
    end
  end

  def display_content(%__MODULE__{content: content, message_type: type, media_urls: media_urls})
      when type in ["image", "file"] do
    media_text =
      case type do
        "image" ->
          is_gif = Enum.any?(media_urls, &String.contains?(&1, ".gif"))
          if is_gif, do: "GIF", else: "Photo"

        "file" ->
          "File"
      end

    if content && String.trim(content) != "" do
      "#{media_text}: #{content}"
    else
      media_text
    end
  end

  @doc """
  Decrypts message content if encrypted.
  """
  def decrypt_content(%__MODULE__{content: content} = message) when not is_nil(content) do
    # Already has plaintext content
    message
  end

  def decrypt_content(%__MODULE__{encrypted_content: nil} = message), do: message

  def decrypt_content(%__MODULE__{encrypted_content: encrypted, sender_id: sender_id} = message)
      when not is_nil(encrypted) do
    case Elektrine.Encryption.decrypt(encrypted, sender_id) do
      {:ok, content} -> %{message | content: content}
      {:error, _} -> %{message | content: "[Decryption failed]"}
    end
  end

  def decrypt_content(message), do: message

  @doc """
  Decrypts a list of messages.
  """
  def decrypt_messages(messages) when is_list(messages) do
    Enum.map(messages, &decrypt_content/1)
  end

  @doc """
  Returns true if the message can be edited by the given user.
  """
  def can_edit?(%__MODULE__{sender_id: sender_id, message_type: type, deleted_at: nil}, user_id)
      when type in ["text", "image", "file"] do
    sender_id == user_id
  end

  def can_edit?(%__MODULE__{}, _user_id), do: false

  @doc """
  Returns true if the message can be deleted by the given user.
  """
  def can_delete?(message, user_id, is_admin \\ false)

  def can_delete?(%__MODULE__{sender_id: sender_id, deleted_at: nil}, user_id, is_admin) do
    is_admin || sender_id == user_id
  end

  def can_delete?(%__MODULE__{}, _user_id, _is_admin), do: false

  # Private helpers

  defp validate_content_or_media(changeset) do
    content = get_field(changeset, :content)
    encrypted_content = get_field(changeset, :encrypted_content)
    media_urls = get_field(changeset, :media_urls) || []
    message_type = get_field(changeset, :message_type)

    has_content = !is_nil(content) && String.trim(content) != ""
    has_encrypted = !is_nil(encrypted_content)
    has_media = !Enum.empty?(media_urls)

    cond do
      message_type == "system" -> changeset
      message_type == "voice" && has_media -> changeset
      has_content or has_encrypted or has_media -> changeset
      true -> add_error(changeset, :content, "must have either content or media")
    end
  end

  defp validate_content_security(changeset) do
    case get_change(changeset, :content) do
      nil ->
        changeset

      content when is_binary(content) ->
        cleaned_content =
          content
          |> String.replace(~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi, "")
          |> String.replace(~r/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/mi, "")
          |> String.replace(~r/javascript:/i, "")

        if String.length(cleaned_content) != String.length(content) do
          add_error(changeset, :content, "contains potentially unsafe content")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_media_urls_security(changeset) do
    case get_change(changeset, :media_urls) do
      nil ->
        changeset

      urls when is_list(urls) ->
        invalid_urls = Enum.filter(urls, fn url -> not trusted_media_url?(url) end)

        if invalid_urls != [] do
          add_error(changeset, :media_urls, "contains untrusted media URLs")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp trusted_media_url?(url) do
    cond do
      String.starts_with?(url, "/uploads/") ->
        true

      String.starts_with?(url, "chat-attachments/") ->
        true

      String.starts_with?(url, "attachments/") ->
        true

      true ->
        trusted_domains = [
          "media.giphy.com",
          "media0.giphy.com",
          "media1.giphy.com",
          "media2.giphy.com",
          "media3.giphy.com",
          "media4.giphy.com",
          "i.giphy.com",
          "i.imgur.com",
          "imgur.com"
        ]

        uri = URI.parse(url)
        uri.scheme == "https" and uri.host in trusted_domains
    end
  end

  defp determine_media_type(media_urls) do
    if Enum.any?(media_urls, &String.match?(&1, ~r/\.(jpg|jpeg|png|gif|webp)$/i)) do
      "image"
    else
      "file"
    end
  end

  defp maybe_encrypt(attrs, _sender_id, false), do: attrs

  defp maybe_encrypt(attrs, sender_id, true) do
    case Map.get(attrs, :content) do
      nil ->
        attrs

      "" ->
        attrs

      content ->
        encrypted = Elektrine.Encryption.encrypt(content, sender_id)
        search_index = Elektrine.Encryption.index_content(content, sender_id)

        attrs
        |> Map.put(:encrypted_content, encrypted)
        |> Map.put(:search_index, search_index)
        |> Map.put(:content, nil)
    end
  end

  defp format_duration(nil), do: "0:00"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end
end
