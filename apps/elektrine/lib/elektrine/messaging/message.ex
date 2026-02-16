defmodule Elektrine.Messaging.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @varchar_limit 255

  schema "messages" do
    field :content, :string
    field :encrypted_content, :map
    field :search_index, {:array, :string}, default: []
    field :message_type, :string, default: "text"
    field :media_urls, {:array, :string}, default: []
    field :media_metadata, :map, default: %{}
    field :edited_at, :utc_datetime
    field :deleted_at, :utc_datetime

    # Social features
    field :visibility, :string, default: "conversation"
    field :post_type, :string, default: "message"
    field :like_count, :integer, default: 0
    field :dislike_count, :integer, default: 0
    field :reply_count, :integer, default: 0
    field :share_count, :integer, default: 0
    field :quote_count, :integer, default: 0

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :sender, Elektrine.Accounts.User
    belongs_to :reply_to, __MODULE__
    belongs_to :link_preview, {"link_previews", Elektrine.Social.LinkPreview}
    has_many :replies, __MODULE__, foreign_key: :reply_to_id
    has_many :reactions, Elektrine.Messaging.MessageReaction, foreign_key: :message_id

    # Cross-context promotion fields
    belongs_to :original_message, __MODULE__
    belongs_to :shared_message, __MODULE__
    # Quote posts (Mastodon-style quoting)
    belongs_to :quoted_message, __MODULE__
    has_many :quoted_by, __MODULE__, foreign_key: :quoted_message_id
    field :promoted_from, :string
    field :share_type, :string
    field :promoted_from_community_name, :string
    field :promoted_from_community_hash, :string

    # Post titles (Reddit-style)
    field :title, :string
    field :auto_title, :boolean, default: false

    # Social features
    field :extracted_urls, {:array, :string}, default: []
    field :extracted_hashtags, {:array, :string}, default: []

    # Discussion voting
    field :upvotes, :integer, default: 0
    field :downvotes, :integer, default: 0
    field :score, :integer, default: 0

    # Community flair
    belongs_to :flair, Elektrine.Messaging.CommunityFlair

    # Pinned post fields
    field :is_pinned, :boolean, default: false
    field :pinned_at, :utc_datetime
    belongs_to :pinned_by, Elektrine.Accounts.User

    # Thread locking fields
    field :locked_at, :utc_datetime
    belongs_to :locked_by, Elektrine.Accounts.User
    field :lock_reason, :string

    # Post approval fields
    field :approval_status, :string
    belongs_to :approved_by, Elektrine.Accounts.User
    field :approved_at, :utc_datetime

    # Post type specific fields
    # For link-type posts
    field :primary_url, :string
    has_one :poll, {"polls", Elektrine.Social.Poll}

    many_to_many :hashtags, {"hashtags", Elektrine.Social.Hashtag},
      join_through: "post_hashtags",
      on_replace: :delete

    # ActivityPub Federation
    # Text in DB (long URLs)
    field :activitypub_id, :string
    # Text in DB (long URLs)
    field :activitypub_url, :string
    field :federated, :boolean, default: false
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    # Content warnings (ActivityPub sensitive content)
    # Text in DB (can be long)
    field :content_warning, :string
    field :sensitive, :boolean, default: false

    # Gallery post category (photography, art, design, anime, meme, other)
    field :category, :string

    # Draft support
    field :is_draft, :boolean, default: false
    field :scheduled_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :sender_id,
      :content,
      :encrypted_content,
      :search_index,
      :message_type,
      :media_urls,
      :media_metadata,
      :reply_to_id,
      :edited_at,
      :deleted_at,
      :visibility,
      :post_type,
      :like_count,
      :dislike_count,
      :reply_count,
      :share_count,
      :link_preview_id,
      :extracted_urls,
      :extracted_hashtags,
      :upvotes,
      :downvotes,
      :score,
      :original_message_id,
      :shared_message_id,
      :quoted_message_id,
      :quote_count,
      :promoted_from,
      :share_type,
      :promoted_from_community_name,
      :promoted_from_community_hash,
      :title,
      :auto_title,
      :flair_id,
      :is_pinned,
      :pinned_at,
      :pinned_by_id,
      :locked_at,
      :locked_by_id,
      :lock_reason,
      :approval_status,
      :approved_by_id,
      :approved_at,
      :primary_url,
      :activitypub_id,
      :activitypub_url,
      :federated,
      :remote_actor_id,
      :content_warning,
      :sensitive,
      :category,
      :is_draft,
      :scheduled_at
    ])
    |> validate_required([:conversation_id, :sender_id])
    |> validate_category()
    |> validate_inclusion(:message_type, ["text", "image", "file", "system"])
    |> validate_inclusion(:visibility, [
      "conversation",
      "followers",
      "friends",
      "private",
      "public"
    ])
    |> validate_inclusion(:post_type, [
      "message",
      "post",
      "comment",
      "share",
      "discussion",
      "link",
      "poll",
      "gallery"
    ])
    |> validate_length(:content, max: 4000)
    |> validate_content_security()
    |> validate_media_urls_security()
    |> validate_content_or_media()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sender_id)
    |> foreign_key_constraint(:reply_to_id)
  end

  @doc """
  Changeset for federated messages from ActivityPub.
  Does not require conversation_id or sender_id.
  """
  def federated_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :content,
      :title,
      :message_type,
      :media_urls,
      :media_metadata,
      :reply_to_id,
      :visibility,
      :post_type,
      :activitypub_id,
      :activitypub_url,
      :federated,
      :remote_actor_id,
      :inserted_at,
      :extracted_hashtags,
      :like_count,
      :dislike_count,
      :reply_count,
      :share_count,
      :quote_count,
      :quoted_message_id
    ])
    |> normalize_federated_columns()
    |> validate_required([:activitypub_id, :remote_actor_id])
    |> put_change(:federated, true)
    |> validate_inclusion(:visibility, ["public", "unlisted", "followers", "private"])
    |> validate_length(:content, max: 4000)
    |> unique_constraint(:activitypub_id)
  end

  # Keep federated inserts safe when upstream payloads exceed varchar-backed fields.
  defp normalize_federated_columns(changeset) do
    changeset
    |> update_change(:title, &truncate_varchar/1)
    |> update_change(:media_urls, &sanitize_federated_media_urls/1)
  end

  defp truncate_varchar(value) when is_binary(value) do
    if String.length(value) > @varchar_limit do
      String.slice(value, 0, @varchar_limit)
    else
      value
    end
  end

  defp truncate_varchar(value), do: value

  defp sanitize_federated_media_urls(urls) when is_list(urls) do
    Enum.filter(urls, fn
      url when is_binary(url) -> String.length(url) <= @varchar_limit
      _ -> false
    end)
  end

  defp sanitize_federated_media_urls(_), do: []

  defp validate_content_or_media(changeset) do
    content = get_field(changeset, :content)
    encrypted_content = get_field(changeset, :encrypted_content)
    media_urls = get_field(changeset, :media_urls) || []
    post_type = get_field(changeset, :post_type)
    primary_url = get_field(changeset, :primary_url)
    is_draft = get_field(changeset, :is_draft)

    # Check if this is valid based on post type
    has_content = !is_nil(content) && String.trim(content) != ""
    has_encrypted = !is_nil(encrypted_content)
    has_media = !Enum.empty?(media_urls)
    has_url = !is_nil(primary_url) && String.trim(primary_url) != ""

    cond do
      # Drafts can be empty - they're work in progress
      is_draft == true ->
        changeset

      # Poll posts need to have post_type set (will be validated separately with poll data)
      post_type == "poll" ->
        changeset

      # Link posts need primary_url
      post_type == "link" && has_url ->
        changeset

      # Link posts without URL
      post_type == "link" && !has_url ->
        add_error(changeset, :primary_url, "is required for link posts")

      # Shared posts (boosts) don't need content
      !is_nil(get_field(changeset, :shared_message_id)) ->
        changeset

      # All other posts need content or media
      has_content or has_encrypted or has_media ->
        changeset

      # Nothing provided
      true ->
        add_error(changeset, :content, "must have either content or media")
    end
  end

  @doc """
  Creates a changeset for a text message.
  """
  def text_changeset(
        conversation_id,
        sender_id,
        content,
        reply_to_id \\ nil,
        conversation_type \\ nil
      ) do
    attrs =
      %{
        conversation_id: conversation_id,
        sender_id: sender_id,
        content: content,
        message_type: "text",
        reply_to_id: reply_to_id
      }
      |> encrypt_content(sender_id, conversation_type)

    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc """
  Creates a changeset for a media message.
  """
  def media_changeset(
        conversation_id,
        sender_id,
        media_urls,
        content \\ nil,
        media_metadata \\ %{},
        conversation_type \\ nil
      ) do
    message_type =
      if Enum.any?(media_urls, &String.match?(&1, ~r/\.(jpg|jpeg|png|gif|webp)$/i)) do
        "image"
      else
        "file"
      end

    attrs =
      %{
        conversation_id: conversation_id,
        sender_id: sender_id,
        content: content,
        message_type: message_type,
        media_urls: media_urls,
        media_metadata: media_metadata
      }
      |> encrypt_content(sender_id, conversation_type)

    %__MODULE__{}
    |> changeset(attrs)
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
  def edit_changeset(message, new_content) do
    # Get conversation type to determine if we should encrypt
    message_with_conversation = Elektrine.Repo.preload(message, :conversation)
    conversation_type = message_with_conversation.conversation.type

    attrs =
      %{
        content: new_content,
        edited_at: DateTime.utc_now()
      }
      |> encrypt_content(message.sender_id, conversation_type)

    message
    |> changeset(attrs)
  end

  @doc """
  Creates a changeset for deleting a message.
  """
  def delete_changeset(message) do
    message
    |> changeset(%{
      deleted_at: DateTime.utc_now()
    })
  end

  @doc """
  Creates a changeset for updating metadata fields only.
  Does not require conversation_id or sender_id, making it safe for federated messages.
  """
  def metadata_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :media_metadata,
      :like_count,
      :dislike_count,
      :reply_count,
      :share_count,
      :upvotes,
      :downvotes,
      :score
    ])
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

  def display_content(%__MODULE__{content: content, message_type: type, media_urls: media_urls})
      when type in ["image", "file"] do
    media_text =
      case type do
        "image" ->
          # Check if it's a GIF based on URL
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
  Extracts direct image URLs from message content.
  Returns a list of image URLs found in the message.
  """
  def extract_image_urls(content) when is_binary(content) do
    # Regex to match URLs
    url_regex = ~r/https?:\/\/[^\s<>"{}|\\^`\[\]]+/i

    # Common image extensions
    image_extensions = ~r/\.(jpg|jpeg|png|gif|webp|svg|bmp|ico)$/i

    # Find all URLs
    Regex.scan(url_regex, content)
    |> Enum.map(&List.first/1)
    |> Enum.filter(fn url ->
      # Check if URL ends with image extension
      # Check for common image hosting patterns
      # Check for Discord CDN images
      # Check for GitHub user content
      String.match?(url, image_extensions) ||
        String.contains?(url, ["imgur.com", "i.imgur.com", "giphy.com", "tenor.com"]) ||
        String.contains?(url, "cdn.discordapp.com/attachments") ||
        String.contains?(url, "user-images.githubusercontent.com")
    end)
    |> Enum.uniq()
  end

  def extract_image_urls(_), do: []

  @doc """
  Checks if a URL is likely an image URL based on extension or common patterns.
  """
  def is_image_url?(url) when is_binary(url) do
    image_extensions = ~r/\.(jpg|jpeg|png|gif|webp|svg|bmp|ico)(\?.*)?$/i

    String.match?(url, image_extensions) ||
      String.contains?(url, ["imgur.com", "i.imgur.com", "giphy.com", "tenor.com"]) ||
      String.contains?(url, "cdn.discordapp.com/attachments") ||
      String.contains?(url, "user-images.githubusercontent.com")
  end

  def is_image_url?(_), do: false

  @doc """
  Extracts YouTube URL from content and converts to embed format.
  Returns nil if no YouTube URL found.
  """
  def extract_youtube_embed_url(content) when is_binary(content) do
    # Match various YouTube URL formats
    cond do
      # youtube.com/watch?v=VIDEO_ID
      Regex.match?(~r/youtube\.com\/watch\?v=([a-zA-Z0-9_-]+)/, content) ->
        case Regex.run(~r/youtube\.com\/watch\?v=([a-zA-Z0-9_-]+)/, content) do
          [_, video_id] -> "https://www.youtube.com/embed/#{video_id}"
          _ -> nil
        end

      # youtu.be/VIDEO_ID
      Regex.match?(~r/youtu\.be\/([a-zA-Z0-9_-]+)/, content) ->
        case Regex.run(~r/youtu\.be\/([a-zA-Z0-9_-]+)/, content) do
          [_, video_id] -> "https://www.youtube.com/embed/#{video_id}"
          _ -> nil
        end

      # youtube.com/embed/VIDEO_ID (already embed format)
      Regex.match?(~r/youtube\.com\/embed\/([a-zA-Z0-9_-]+)/, content) ->
        case Regex.run(~r/(https?:\/\/[^\s]+youtube\.com\/embed\/[a-zA-Z0-9_-]+)/, content) do
          [url | _] -> url
          _ -> nil
        end

      true ->
        nil
    end
  end

  def extract_youtube_embed_url(_), do: nil

  @doc """
  Returns true if the message can be edited by the given user.
  """
  def can_edit?(%__MODULE__{sender_id: sender_id, message_type: "text", deleted_at: nil}, user_id) do
    sender_id == user_id
  end

  def can_edit?(%__MODULE__{}, _user_id), do: false

  @doc """
  Returns true if the message can be deleted by the given user.
  Admins can delete any message, users can only delete their own messages.
  """
  def can_delete?(message, user_id, is_admin \\ false)

  def can_delete?(%__MODULE__{sender_id: sender_id, deleted_at: nil}, user_id, is_admin) do
    is_admin || sender_id == user_id
  end

  def can_delete?(%__MODULE__{}, _user_id, _is_admin), do: false

  @doc """
  Encrypts message content and creates search index.
  Returns updated attrs with encrypted_content and search_index.
  Clears the plaintext content field to avoid storing unencrypted data.

  IMPORTANT: Chat conversations (dm/group/channel) are stored in plaintext.
  Email encryption is handled separately in Elektrine.Email.Message.
  """
  def encrypt_content(attrs, user_id, conversation_type \\ nil) do
    is_chat_conversation = conversation_type in ["dm", "group", "channel"]

    # Messaging posts are plaintext for timeline/community/chat.
    # Keep encryption enabled only for unknown callers that don't pass a conversation type.
    should_encrypt =
      case conversation_type do
        "timeline" -> false
        "community" -> false
        "dm" -> false
        "group" -> false
        "channel" -> false
        _ -> true
      end

    if should_encrypt do
      case Map.get(attrs, :content) do
        nil ->
          attrs

        "" ->
          attrs

        content ->
          encrypted = Elektrine.Encryption.encrypt(content, user_id)
          search_index = Elektrine.Encryption.index_content(content, user_id)

          attrs
          |> Map.put(:encrypted_content, encrypted)
          |> Map.put(:search_index, search_index)
          # Clear plaintext
          |> Map.put(:content, nil)
      end
    else
      # Keep chat content plaintext, but maintain blind-search index for message search.
      if is_chat_conversation do
        case Map.get(attrs, :content) do
          nil ->
            attrs
            |> Map.put(:encrypted_content, nil)
            |> Map.put(:search_index, [])

          "" ->
            attrs
            |> Map.put(:encrypted_content, nil)
            |> Map.put(:search_index, [])

          content ->
            attrs
            |> Map.put(:encrypted_content, nil)
            |> Map.put(:search_index, Elektrine.Encryption.index_content(content, user_id))
        end
      else
        attrs
      end
    end
  end

  @doc """
  Decrypts message content if encrypted.
  Returns the message with decrypted content in the :content field.

  OPTIMIZATION: Timeline/community/chat posts are stored as plaintext, so this is usually a no-op.
  """
  def decrypt_content(%__MODULE__{content: content} = message) when not is_nil(content) do
    # Already has plaintext content - no decryption needed
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

  # Security validation functions

  defp validate_content_security(changeset) do
    case get_change(changeset, :content) do
      nil ->
        changeset

      content when is_binary(content) ->
        # Basic XSS prevention - strip potentially dangerous content
        cleaned_content =
          content
          |> String.replace(~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi, "")
          |> String.replace(~r/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/mi, "")
          |> String.replace(~r/<object\b[^<]*(?:(?!<\/object>)<[^<]*)*<\/object>/mi, "")
          |> String.replace(~r/<embed\b[^<]*>/mi, "")
          |> String.replace(~r/javascript:/i, "")
          |> String.replace(~r/data:(?!image)/i, "")

        # Check for excessive mentions or spam patterns
        if String.length(cleaned_content) != String.length(content) do
          add_error(changeset, :content, "contains potentially unsafe content")
        else
          validate_spam_patterns(changeset, cleaned_content)
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
        # Validate all URLs are from trusted domains
        invalid_urls =
          Enum.filter(urls, fn url ->
            not is_trusted_media_url?(url)
          end)

        if invalid_urls != [] do
          add_error(changeset, :media_urls, "contains untrusted media URLs")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_spam_patterns(changeset, content) do
    cond do
      # Too many mentions
      length(Regex.scan(~r/@\w+/, content)) > 10 ->
        add_error(changeset, :content, "contains too many mentions")

      # Too many emojis
      String.graphemes(content) |> Enum.count(&is_emoji?/1) > 50 ->
        add_error(changeset, :content, "contains too many emojis")

      true ->
        changeset
    end
  end

  defp is_trusted_media_url?(url) do
    # Allow local uploads (paths starting with /uploads/)
    cond do
      String.starts_with?(url, "/uploads/") ->
        true

      # Allow S3/R2 keys (paths starting with various attachment folders)
      String.starts_with?(url, "attachments/") or
        String.starts_with?(url, "chat-attachments/") or
        String.starts_with?(url, "timeline-attachments/") or
        String.starts_with?(url, "discussion-attachments/") or
        String.starts_with?(url, "gallery-attachments/") or
        String.starts_with?(url, "email-attachments/") or
        String.starts_with?(url, "avatars/") or
          String.starts_with?(url, "backgrounds/") ->
        true

      # Allow HTTPS URLs from trusted domains
      true ->
        trusted_domains = [
          "media.giphy.com",
          "media0.giphy.com",
          "media1.giphy.com",
          "media2.giphy.com",
          "media3.giphy.com",
          "media4.giphy.com",
          "i.giphy.com",
          "avatars.githubusercontent.com",
          "user-images.githubusercontent.com",
          "raw.githubusercontent.com",
          "i.imgur.com",
          "imgur.com",
          Application.get_env(:elektrine, :uploads)[:domain] || "localhost"
        ]

        uri = URI.parse(url)

        # Must be HTTPS and from trusted domain for external URLs
        uri.scheme == "https" and
          uri.host in trusted_domains
    end
  end

  defp is_emoji?(grapheme) do
    # Simple emoji detection - check for common emoji codepoints
    codepoint = String.to_charlist(grapheme) |> List.first()
    # Emoticons
    # Misc Symbols
    # Transport
    # Misc symbols
    # Dingbats
    codepoint != nil and
      ((codepoint >= 0x1F600 and codepoint <= 0x1F64F) or
         (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) or
         (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) or
         (codepoint >= 0x2600 and codepoint <= 0x26FF) or
         (codepoint >= 0x2700 and codepoint <= 0x27BF))
  rescue
    _ -> false
  end

  # Category is optional but must be valid if provided
  defp validate_category(changeset) do
    case get_change(changeset, :category) do
      nil ->
        changeset

      category ->
        valid_categories = ["photography", "art", "design", "anime", "meme", "other"]

        if category in valid_categories do
          changeset
        else
          add_error(changeset, :category, "must be one of: #{Enum.join(valid_categories, ", ")}")
        end
    end
  end
end
