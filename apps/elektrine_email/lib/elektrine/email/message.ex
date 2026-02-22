defmodule Elektrine.Email.Message do
  @moduledoc """
  Schema for email messages with encryption support and Hey.com-inspired features.
  Supports encrypted body content, attachments, categorization, spam filtering, and reply-later functionality.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_messages" do
    field :message_id, :string
    field :from, :string
    field :to, :string
    field :cc, :string
    field :bcc, :string
    field :subject, :string
    field :text_body, :string
    field :html_body, :string
    field :encrypted_text_body, :map
    field :encrypted_html_body, :map
    field :search_index, {:array, :string}, default: []
    # received, sent, draft
    field :status, :string, default: "received"
    field :read, :boolean, default: false
    field :spam, :boolean, default: false
    field :archived, :boolean, default: false
    field :deleted, :boolean, default: false
    field :flagged, :boolean, default: false
    field :answered, :boolean, default: false
    field :metadata, :map, default: %{}

    # Hey.com features
    field :category, :string, default: "inbox"
    field :stack_at, :utc_datetime
    field :stack_reason, :string
    field :reply_later_at, :utc_datetime
    field :reply_later_reminder, :boolean, default: false
    field :is_receipt, :boolean, default: false
    field :is_notification, :boolean, default: false
    field :is_newsletter, :boolean, default: false
    field :opened_at, :utc_datetime
    field :first_opened_at, :utc_datetime
    field :open_count, :integer, default: 0

    # Attachments
    field :attachments, :map, default: %{}
    field :has_attachments, :boolean, default: false
    field :hash, :string

    # JMAP fields
    field :in_reply_to, :string
    field :references, :string
    field :jmap_blob_id, :string

    # Priority and scheduling
    field :priority, :string, default: "normal"
    field :scheduled_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :undo_send_until, :utc_datetime

    belongs_to :mailbox, Elektrine.Email.Mailbox
    belongs_to :thread, Elektrine.JMAP.Thread
    belongs_to :folder, Elektrine.Email.Folder

    many_to_many :labels, Elektrine.Email.Label, join_through: "email_message_labels"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a new email message.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :message_id,
      :from,
      :to,
      :cc,
      :bcc,
      :subject,
      :text_body,
      :html_body,
      :encrypted_text_body,
      :encrypted_html_body,
      :search_index,
      :status,
      :read,
      :spam,
      :archived,
      :deleted,
      :flagged,
      :answered,
      :metadata,
      :mailbox_id,
      :category,
      :stack_at,
      :stack_reason,
      :reply_later_at,
      :reply_later_reminder,
      :is_receipt,
      :is_notification,
      :is_newsletter,
      :opened_at,
      :first_opened_at,
      :open_count,
      :attachments,
      :has_attachments,
      :inserted_at,
      :updated_at,
      :thread_id,
      :in_reply_to,
      :references,
      :jmap_blob_id,
      :priority,
      :scheduled_at,
      :expires_at,
      :undo_send_until,
      :folder_id
    ])
    |> validate_inclusion(:priority, ~w(low normal high))
    |> validate_required_fields()
    |> validate_length(:message_id, max: 500)
    |> validate_length(:from, max: 500)
    |> validate_length(:to, max: 10_000)
    |> validate_length(:cc, max: 10_000)
    |> validate_length(:bcc, max: 10_000)
    |> validate_length(:subject, max: 500)
    |> validate_length(:stack_reason, max: 255)
    |> set_has_attachments()
    |> generate_hash_if_needed()
    |> unique_constraint([:message_id, :mailbox_id])

    # No foreign key constraint anymore - we manually handle the association
  end

  # Automatically set has_attachments based on attachments field
  defp set_has_attachments(changeset) do
    case get_field(changeset, :attachments) do
      attachments when is_map(attachments) and map_size(attachments) > 0 ->
        put_change(changeset, :has_attachments, true)

      _ ->
        put_change(changeset, :has_attachments, false)
    end
  end

  @doc """
  Mark a message as read.
  """
  def read_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:read, true)
  end

  @doc """
  Mark a message as unread.
  """
  def unread_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:read, false)
  end

  @doc """
  Mark a message as spam.
  """
  def spam_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:spam, true)
  end

  @doc """
  Mark a message as not spam.
  """
  def unspam_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:spam, false)
  end

  @doc """
  Archive a message.
  """
  def archive_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:archived, true)
  end

  @doc """
  Unarchive a message.
  """
  def unarchive_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:archived, false)
  end

  @doc """
  Moves a message to trash.
  """
  def trash_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:deleted, true)
  end

  @doc """
  Restores a message from trash.
  """
  def untrash_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:deleted, false)
  end

  @doc """
  Add a message to the stack for later.
  """
  def stack_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [:stack_reason])
    |> put_change(:category, "stack")
    |> put_change(:stack_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Move message back from stack.
  """
  def unstack_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:category, "inbox")
    |> put_change(:stack_at, nil)
    |> put_change(:stack_reason, nil)
  end

  @doc """
  Set a message for reply later.
  """
  def reply_later_changeset(message, attrs) do
    message
    |> cast(attrs, [:reply_later_at, :reply_later_reminder])
    |> validate_required([:reply_later_at])
  end

  @doc """
  Clear reply later for a message.
  """
  def clear_reply_later_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:reply_later_at, nil)
    |> put_change(:reply_later_reminder, false)
  end

  @doc """
  Track when a message is opened.
  """
  def track_open_changeset(message, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      message
      |> cast(attrs, [])
      |> put_change(:opened_at, now)
      |> put_change(:open_count, (message.open_count || 0) + 1)

    if is_nil(message.first_opened_at) do
      changeset |> put_change(:first_opened_at, now)
    else
      changeset
    end
  end

  # Validate required fields based on message status
  defp validate_required_fields(changeset) do
    status = get_field(changeset, :status)

    if status == "draft" do
      # Drafts only require message_id, from, and mailbox_id
      validate_required(changeset, [:message_id, :from, :mailbox_id])
    else
      # Regular messages require to field as well
      validate_required(changeset, [:message_id, :from, :to, :mailbox_id])
    end
  end

  @doc """
  Encrypts email body content and creates search index.
  Returns updated attrs with encrypted bodies and search_index.
  Clears the plaintext body fields to avoid storing unencrypted data.
  """
  def encrypt_content(attrs, user_id) do
    # Get original content before encryption (for search index)
    original_text = Map.get(attrs, :text_body)
    original_html = Map.get(attrs, :html_body)

    # Encrypt text_body if present
    attrs =
      case original_text do
        nil ->
          attrs

        "" ->
          attrs

        text_body ->
          encrypted = Elektrine.Encryption.encrypt(text_body, user_id)

          attrs
          |> Map.put(:encrypted_text_body, encrypted)
          # Clear plaintext
          |> Map.put(:text_body, nil)
      end

    # Encrypt html_body if present
    attrs =
      case original_html do
        nil ->
          attrs

        "" ->
          attrs

        html_body ->
          encrypted = Elektrine.Encryption.encrypt(html_body, user_id)

          attrs
          |> Map.put(:encrypted_html_body, encrypted)
          # Clear plaintext
          |> Map.put(:html_body, nil)
      end

    # Create search index from text_body (prefer text over html for indexing)
    search_content = original_text || original_html || ""

    if search_content != "" do
      search_index = Elektrine.Encryption.index_content(search_content, user_id)
      Map.put(attrs, :search_index, search_index)
    else
      attrs
    end
  end

  @doc """
  Decrypts email message content if encrypted.
  Returns the message with decrypted content in the body fields.
  """
  def decrypt_content(%__MODULE__{encrypted_text_body: nil, encrypted_html_body: nil} = message),
    do: message

  def decrypt_content(%__MODULE__{mailbox: %{user_id: user_id}} = message) do
    decrypt_content(message, user_id)
  end

  def decrypt_content(message) when not is_integer(message), do: message

  def decrypt_content(
        %__MODULE__{encrypted_text_body: nil, encrypted_html_body: nil} = message,
        _user_id
      ),
      do: message

  def decrypt_content(%__MODULE__{} = message, user_id) when is_integer(user_id) do
    message =
      case message.encrypted_text_body do
        nil ->
          message

        encrypted ->
          case Elektrine.Encryption.decrypt(encrypted, user_id) do
            {:ok, text_body} -> %{message | text_body: text_body}
            {:error, _} -> %{message | text_body: "[Decryption failed]"}
          end
      end

    case message.encrypted_html_body do
      nil ->
        message

      encrypted ->
        case Elektrine.Encryption.decrypt(encrypted, user_id) do
          {:ok, html_body} -> %{message | html_body: html_body}
          {:error, _} -> %{message | html_body: "[Decryption failed]"}
        end
    end
  end

  @doc """
  Decrypts a list of email messages.
  """
  def decrypt_messages(messages, user_id) when is_list(messages) and is_integer(user_id) do
    Enum.map(messages, &decrypt_content(&1, user_id))
  end

  def decrypt_messages(messages, _user_id), do: messages

  @doc """
  Sets the priority for a message.
  """
  def priority_changeset(message, priority) when priority in ["low", "normal", "high"] do
    message
    |> cast(%{priority: priority}, [:priority])
    |> validate_inclusion(:priority, ~w(low normal high))
  end

  @doc """
  Schedules a message for later sending.
  """
  def schedule_changeset(message, attrs) do
    message
    |> cast(attrs, [:scheduled_at])
    |> validate_required([:scheduled_at])
    |> validate_future_date(:scheduled_at)
  end

  @doc """
  Clears scheduled sending for a message.
  """
  def clear_schedule_changeset(message, attrs \\ %{}) do
    message
    |> cast(attrs, [])
    |> put_change(:scheduled_at, nil)
  end

  @doc """
  Sets expiration time for a message.
  """
  def expiration_changeset(message, attrs) do
    message
    |> cast(attrs, [:expires_at])
    |> validate_future_date(:expires_at)
  end

  @doc """
  Sets undo send window for a message.
  """
  def undo_send_changeset(message, seconds \\ 30) do
    undo_until =
      DateTime.utc_now()
      |> DateTime.add(seconds, :second)
      |> DateTime.truncate(:second)

    message
    |> change()
    |> put_change(:undo_send_until, undo_until)
  end

  @doc """
  Clears undo send window.
  """
  def clear_undo_send_changeset(message) do
    message
    |> change()
    |> put_change(:undo_send_until, nil)
  end

  @doc """
  Moves a message to a custom folder.
  """
  def move_to_folder_changeset(message, folder_id) do
    message
    |> change()
    |> put_change(:folder_id, folder_id)
  end

  defp validate_future_date(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      datetime ->
        if DateTime.compare(datetime, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, field, "must be in the future")
        end
    end
  end

  # Generate a unique hash for the message if it doesn't have one
  defp generate_hash_if_needed(changeset) do
    case get_field(changeset, :hash) do
      nil ->
        hash = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        put_change(changeset, :hash, hash)

      _ ->
        changeset
    end
  end
end
