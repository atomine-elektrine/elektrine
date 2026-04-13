defmodule Elektrine.Email.Messages do
  @moduledoc """
  Message CRUD and query operations.
  Handles message creation, retrieval, updates, deletion, and basic queries.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Ecto.Multi
  alias Elektrine.Email.{CacheHooks, Mailbox, MailboxEncryption, Message}
  alias Elektrine.JMAP
  alias Elektrine.Repo
  alias Elektrine.Telemetry.Events

  # Private helper to decrypt email messages
  defp decrypt_email_messages(messages, mailbox_id) when is_list(messages) do
    case Elektrine.Email.Mailboxes.get_mailbox(mailbox_id) do
      %Mailbox{user_id: user_id} when not is_nil(user_id) ->
        Message.decrypt_messages(messages, user_id)

      _ ->
        messages
    end
  end

  @doc """
  Gets a single message for admin operations (bypasses ownership checks).

  WARNING: Only use this for admin operations where access control is handled
  at the plug/authorization layer. For regular user operations, use get_user_message/2.
  """
  def get_message_admin(id), do: Repo.get(Message, id)

  @doc """
  Gets a single message for internal system operations (bypasses ownership checks).

  WARNING: Only use this for internal background jobs and system operations that
  don't involve user requests. For user-facing operations, use get_user_message/2.

  Examples: attachment processors, email cleanup jobs, system migrations.
  """
  def get_message_internal(id), do: Repo.get(Message, id)

  @doc """
  Gets a single message for a specific mailbox.
  Returns nil if the Message does not exist for that mailbox.
  """
  def get_message(id, mailbox_id) do
    message =
      Message
      |> where(id: ^id, mailbox_id: ^mailbox_id)
      |> Repo.one()

    case message do
      nil ->
        nil

      msg ->
        case Elektrine.Email.Mailboxes.get_mailbox(mailbox_id) do
          %Mailbox{user_id: user_id} when not is_nil(user_id) ->
            Message.decrypt_content(msg, user_id)

          _ ->
            msg
        end
    end
  end

  @doc """
  Gets a message by its hash.
  """
  def get_message_by_hash(hash) do
    message =
      Message
      |> where(hash: ^hash)
      |> Repo.one()

    case message do
      nil ->
        nil

      msg ->
        case Elektrine.Email.Mailboxes.get_mailbox(msg.mailbox_id) do
          %Mailbox{user_id: user_id} when not is_nil(user_id) ->
            Message.decrypt_content(msg, user_id)

          _ ->
            msg
        end
    end
  end

  @doc """
  Gets a message by hash for a specific user with ownership validation.
  """
  def get_user_message_by_hash(hash, user_id)
      when is_binary(hash) and is_integer(user_id) do
    case Repo.one(
           from m in Message,
             join: mb in Mailbox,
             on: mb.id == m.mailbox_id,
             where: m.hash == ^hash,
             select: {m, mb.user_id, mb.email}
         ) do
      {message, ^user_id, _mailbox_email} ->
        {:ok, Message.decrypt_content(message, user_id)}

      {message, nil, mailbox_email} ->
        case Elektrine.Email.verify_email_ownership(mailbox_email, user_id) do
          {:ok, _ownership_type} ->
            Logger.info("Granted access to orphaned mailbox message for verified user #{user_id}")
            {:ok, Message.decrypt_content(message, user_id)}

          {:error, _reason} ->
            Logger.warning("Denied access to orphaned mailbox message for user #{user_id}")
            {:error, :access_denied}
        end

      {_message, _other_user_id, _mailbox_email} ->
        {:error, :access_denied}

      nil ->
        {:error, :message_not_found}
    end
  end

  @doc """
  Gets a single message by its message_id for a specific mailbox.
  Returns nil if the Message does not exist for that mailbox.
  This is used to prevent duplicate message creation.
  """
  def get_message_by_id(message_id, mailbox_id) do
    Message
    |> where(message_id: ^message_id, mailbox_id: ^mailbox_id)
    |> Repo.one()
  end

  @doc """
  Gets a message for a user with ownership validation.
  Ensures users can only access emails sent to addresses they own.
  """
  def get_user_message(message_id, user_id) when is_integer(message_id) and is_integer(user_id) do
    case Repo.get(Message, message_id) do
      %Message{} = message ->
        # Verify user owns the mailbox this message belongs to
        case Elektrine.Email.Mailboxes.get_mailbox(message.mailbox_id) do
          %Mailbox{user_id: ^user_id} ->
            # User owns the mailbox, access allowed - decrypt before returning
            decrypted_message = Message.decrypt_content(message, user_id)
            {:ok, decrypted_message}

          %Mailbox{user_id: other_user_id} when is_integer(other_user_id) ->
            # Message belongs to different user
            {:error, :access_denied}

          %Mailbox{user_id: nil, email: mailbox_email} ->
            # Orphaned mailbox - check if user should have access via email ownership
            case Elektrine.Email.verify_email_ownership(mailbox_email, user_id) do
              {:ok, _ownership_type} ->
                Logger.info(
                  "Granted access to orphaned mailbox message for verified user #{user_id}"
                )

                decrypted_message = Message.decrypt_content(message, user_id)
                {:ok, decrypted_message}

              {:error, _reason} ->
                Logger.warning("Denied access to orphaned mailbox message for user #{user_id}")
                {:error, :access_denied}
            end

          nil ->
            {:error, :mailbox_not_found}
        end

      nil ->
        {:error, :message_not_found}
    end
  end

  @doc """
  Returns the list of messages for a user.
  """
  def list_user_messages(user_id, limit \\ 50, offset \\ 0) do
    mailbox = Elektrine.Email.Mailboxes.get_user_mailbox(user_id)

    if mailbox do
      list_messages(mailbox.id, limit, offset)
    else
      []
    end
  end

  @doc """
  Lists messages for a user with ownership validation.
  Only returns messages from mailboxes the user owns.
  """
  def list_user_messages_secure(user_id, limit \\ 50, offset \\ 0) when is_integer(user_id) do
    # Get user's main mailbox
    case Elektrine.Email.Mailboxes.get_user_mailbox(user_id) do
      %Mailbox{id: mailbox_id} ->
        list_messages(mailbox_id, limit, offset)

      nil ->
        []
    end
  end

  @doc """
  Returns the list of messages for a mailbox.
  """
  def list_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists all messages in the same email thread for a mailbox, ordered oldest-first.
  Includes the current message in the returned list.
  """
  def list_thread_messages(%Message{} = message, mailbox_id) when is_integer(mailbox_id) do
    if message.mailbox_id == mailbox_id && is_integer(message.thread_id) do
      Message
      |> where([m], m.mailbox_id == ^mailbox_id and m.thread_id == ^message.thread_id)
      |> order_by([m], asc: m.inserted_at, asc: m.id)
      |> Repo.all()
      |> filter_related_thread_messages(message)
      |> decrypt_email_messages(mailbox_id)
    else
      []
    end
  end

  def list_thread_messages(_message, _mailbox_id), do: []

  defp filter_related_thread_messages(messages, %Message{id: current_message_id}) do
    identity_sets = Map.new(messages, &{&1.id, thread_identity_set(&1)})

    if Map.has_key?(identity_sets, current_message_id) do
      connected_ids =
        collect_connected_thread_message_ids(MapSet.new([current_message_id]), identity_sets)

      Enum.filter(messages, &MapSet.member?(connected_ids, &1.id))
    else
      messages
    end
  end

  defp collect_connected_thread_message_ids(connected_ids, identity_sets) do
    expanded_ids =
      Enum.reduce(identity_sets, connected_ids, fn {message_id, identity_set}, acc ->
        if MapSet.member?(acc, message_id) or
             connected_to_thread_component?(identity_set, acc, identity_sets) do
          MapSet.put(acc, message_id)
        else
          acc
        end
      end)

    if MapSet.equal?(expanded_ids, connected_ids) do
      expanded_ids
    else
      collect_connected_thread_message_ids(expanded_ids, identity_sets)
    end
  end

  defp connected_to_thread_component?(identity_set, connected_ids, identity_sets) do
    Enum.any?(connected_ids, fn connected_id ->
      case Map.get(identity_sets, connected_id) do
        nil -> false
        connected_identity_set -> not MapSet.disjoint?(identity_set, connected_identity_set)
      end
    end)
  end

  defp thread_identity_set(message) do
    [normalize_message_id(message.message_id), normalize_message_id(message.in_reply_to)]
    |> Kernel.++(parse_reference_ids(message.references))
    |> Enum.reject(&blank_value?/1)
    |> MapSet.new()
  end

  @doc """
  Returns the list of non-spam, non-archived messages for a mailbox, excluding bulk and paper trail.
  """
  def list_inbox_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> where([m], m.category not in ["feed", "ledger", "stack"])
    |> where([m], is_nil(m.reply_later_at))
    |> where([m], is_nil(m.folder_id))
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns the list of spam messages for a mailbox.
  """
  def list_spam_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id, spam: true, archived: false, deleted: false)
    |> where([m], is_nil(m.folder_id))
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns the list of archived messages for a mailbox.
  """
  def list_archived_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id, archived: true, deleted: false)
    |> where([m], is_nil(m.folder_id))
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns the list of unread messages for a user.
  """
  def list_user_unread_messages(user_id) do
    mailbox = Elektrine.Email.Mailboxes.get_user_mailbox(user_id)

    if mailbox do
      list_unread_messages(mailbox.id)
    else
      []
    end
  end

  @doc """
  Returns the list of unread messages for a mailbox.
  """
  def list_unread_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> where([m], m.category not in ["feed", "ledger", "stack"])
    |> where([m], is_nil(m.reply_later_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a message.
  """
  def create_message(attrs \\ %{}) do
    # Calculate message size before creation
    message_size = calculate_message_size(attrs)

    mailbox_id =
      attrs
      |> get_attr(:mailbox_id)
      |> normalize_mailbox_id()

    mailbox =
      if is_integer(mailbox_id) do
        Elektrine.Email.Mailboxes.get_mailbox(mailbox_id)
      else
        nil
      end

    mailbox_user_id =
      case mailbox do
        %Mailbox{user_id: user_id} when is_integer(user_id) -> user_id
        _ -> nil
      end

    # Check storage limit using centralized user storage
    storage_check =
      if mailbox_user_id do
        if Elektrine.Accounts.Storage.would_exceed_limit?(mailbox_user_id, message_size) do
          {:error, :storage_limit_exceeded}
        else
          :ok
        end
      else
        :ok
      end

    case storage_check do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        # Categorize the message before inserting (only if category not already set)
        status = get_attr(attrs, :status)
        is_spam_message = truthy?(get_attr(attrs, :spam))
        categorize_opts = if mailbox_user_id, do: [user_id: mailbox_user_id], else: []

        categorized_attrs =
          if status != "sent" and !is_spam_message do
            # Only categorize incoming messages, not sent messages
            # Skip categorization if category is already explicitly set
            has_category = Map.has_key?(attrs, :category) or Map.has_key?(attrs, "category")

            categorized =
              if has_category,
                do: %{},
                else: Elektrine.Email.Processing.categorize_message(attrs, categorize_opts)

            # Merge categorization results, using the same key type as input
            # Detect key type by checking if any key is an atom
            has_atom_keys = Enum.any?(Map.keys(attrs), &is_atom/1)

            if has_atom_keys do
              # Atom keys - only set if not already present
              attrs
              |> Map.put_new(:category, categorized["category"] || "inbox")
              |> Map.put_new(:is_newsletter, categorized["is_newsletter"] || false)
              |> Map.put_new(:is_receipt, categorized["is_receipt"] || false)
              |> Map.put_new(:is_notification, categorized["is_notification"] || false)
            else
              # String keys - only set if not already present
              attrs
              |> Map.put_new("category", categorized["category"] || "inbox")
              |> Map.put_new("is_newsletter", categorized["is_newsletter"] || false)
              |> Map.put_new("is_receipt", categorized["is_receipt"] || false)
              |> Map.put_new("is_notification", categorized["is_notification"] || false)
            end
          else
            attrs
          end

        # Normalize and enrich threading fields before insert.
        threaded_attrs =
          categorized_attrs
          |> normalize_threading_fields()
          |> maybe_build_thread_references(mailbox_id)
          |> maybe_assign_thread(mailbox_id)

        with {:ok, stored_attrs} <-
               prepare_storage_attrs(threaded_attrs, mailbox, mailbox_user_id),
             {:ok, message} <-
               %Message{}
               |> Message.changeset(stored_attrs)
               |> Repo.insert() do
          bump_message_creation_states(mailbox_id, message.id)

          if mailbox_id do
            # Broadcast to any LiveViews monitoring this mailbox
            Phoenix.PubSub.broadcast!(
              Elektrine.PubSub,
              "mailbox:#{mailbox_id}",
              {:new_email, message}
            )

            # Also broadcast to user topic for notifications
            if mailbox_user_id do
              Phoenix.PubSub.broadcast!(
                Elektrine.PubSub,
                "user:#{mailbox_user_id}",
                {:new_email, message}
              )

              # Only create notifications for actual incoming mail, not self-addressed inbox copies.
              if threaded_attrs[:status] != "sent" && threaded_attrs["status"] != "sent" &&
                   !self_email_attrs?(threaded_attrs) do
                # Create notification for new email if user has enabled it
                user = Elektrine.Accounts.get_user!(mailbox_user_id)

                if Map.get(user, :notify_on_email_received, true) do
                  from_email = threaded_attrs[:from] || threaded_attrs["from"] || "Unknown sender"

                  subject =
                    notification_subject(mailbox, threaded_attrs) || "(Encrypted message)"

                  Elektrine.Notifications.create_notification(%{
                    user_id: mailbox_user_id,
                    type: "email_received",
                    title: "Email from #{from_email}",
                    body: subject,
                    url: Elektrine.Paths.email_view_path(message),
                    source_type: "email",
                    source_id: message.id,
                    priority: "normal"
                  })
                end
              end
            end
          end

          # Decrypt message before returning
          decrypted_message =
            if mailbox_user_id do
              Message.decrypt_content(message, mailbox_user_id)
            else
              message
            end

          # Return the result with cache invalidation
          CacheHooks.with_cache_invalidation({:ok, decrypted_message})
        else
          {:error, reason} ->
            {:error, reason}

          error ->
            error
        end
    end
  end

  @doc """
  Updates a message.
  """
  def update_message(%Message{} = message, attrs) do
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      message
      |> Message.changeset(attrs)
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    # Broadcast unread count update if the operation might affect unread status
    # (message was unread and is being moved, deleted, archived, etc.)
    if was_unread and match?({:ok, _}, result) do
      # Check if the attrs change visibility of the message (deleted, archived, spam)
      should_broadcast =
        Map.has_key?(attrs, :deleted) or
          Map.has_key?(attrs, :archived) or
          Map.has_key?(attrs, :spam) or
          Map.has_key?(attrs, :read)

      if should_broadcast do
        broadcast_unread_count_update(mailbox_id)
      end
    end

    if match?({:ok, _}, result) do
      bump_states_for_update(mailbox_id, message.id, attrs)
    end

    result
  end

  @doc """
  Saves a draft message. Creates new if draft_id is nil, otherwise updates existing draft.
  """
  def save_draft(attrs, draft_id \\ nil) do
    # Ensure status is draft
    attrs = Map.put(attrs, :status, "draft")

    # Generate a unique message_id if not present
    attrs =
      if Map.get(attrs, :message_id) || Map.get(attrs, "message_id") do
        attrs
      else
        Map.put(
          attrs,
          :message_id,
          Elektrine.EmailAddresses.message_id("draft-#{Ecto.UUID.generate()}")
        )
      end

    if draft_id do
      # Update existing draft
      case Repo.get(Message, draft_id) do
        nil ->
          {:error, :not_found}

        draft ->
          if draft.status == "draft" do
            mailbox = Elektrine.Email.Mailboxes.get_mailbox(draft.mailbox_id)

            mailbox_user_id =
              case mailbox do
                %Mailbox{user_id: user_id} when is_integer(user_id) -> user_id
                _ -> nil
              end

            case prepare_storage_attrs(attrs, mailbox, mailbox_user_id) do
              {:ok, stored_attrs} ->
                result =
                  draft
                  |> Message.changeset(stored_attrs)
                  |> Repo.update()
                  |> CacheHooks.with_cache_invalidation()

                if match?({:ok, _}, result) do
                  bump_states_for_update(draft.mailbox_id, draft.id, stored_attrs)
                end

                result

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, :not_a_draft}
          end
      end
    else
      # Create new draft
      create_message(attrs)
    end
  end

  @doc """
  Gets a draft message by ID for a specific mailbox.
  """
  def get_draft(draft_id, mailbox_id) do
    Message
    |> where([m], m.id == ^draft_id and m.mailbox_id == ^mailbox_id and m.status == "draft")
    |> Repo.one()
  end

  @doc """
  Deletes a draft message.
  """
  def delete_draft(draft_id, mailbox_id) do
    case get_draft(draft_id, mailbox_id) do
      nil ->
        {:error, :not_found}

      draft ->
        result =
          Multi.new()
          |> Multi.delete(:draft, draft)
          |> Multi.run(:tombstone, fn _repo, _changes ->
            case JMAP.record_email_destroyed(mailbox_id, draft.id, ["Mailbox", "Thread"]) do
              :ok -> {:ok, :recorded}
              other -> other
            end
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{draft: deleted_draft}} -> {:ok, deleted_draft}
            {:error, _step, reason, _changes} -> {:error, reason}
          end

        result
    end
  end

  defp prepare_storage_attrs(attrs, %Mailbox{} = mailbox, mailbox_user_id) do
    cond do
      MailboxEncryption.enabled?(mailbox) ->
        MailboxEncryption.encrypt_message(attrs, mailbox)

      mailbox_user_id ->
        {:ok, Message.encrypt_content(attrs, mailbox_user_id)}

      true ->
        {:ok, attrs}
    end
  end

  defp prepare_storage_attrs(attrs, _mailbox, mailbox_user_id) when is_integer(mailbox_user_id) do
    {:ok, Message.encrypt_content(attrs, mailbox_user_id)}
  end

  defp prepare_storage_attrs(attrs, _mailbox, _mailbox_user_id), do: {:ok, attrs}

  defp notification_subject(%Mailbox{} = mailbox, attrs) do
    if MailboxEncryption.enabled?(mailbox) do
      MailboxEncryption.placeholder_subject()
    else
      get_attr(attrs, :subject)
    end
  end

  defp self_email_attrs?(attrs) when is_map(attrs) do
    metadata = get_attr(attrs, :metadata)

    case metadata do
      metadata when is_map(metadata) ->
        Map.get(metadata, :self_email) == true || Map.get(metadata, "self_email") == true

      _ ->
        false
    end
  end

  @doc """
  Updates message attachments (for storage management).
  """
  def update_message_attachments(%Message{} = message, attachments, has_attachments) do
    update_message(message, %{attachments: attachments, has_attachments: has_attachments})
  end

  @doc """
  Marks a message as read.
  """
  def mark_as_read(%Message{} = message) do
    result =
      message
      |> Message.read_changeset()
      |> Repo.update()

    case result do
      {:ok, updated_message} ->
        # Get the mailbox to find the user_id
        mailbox = Elektrine.Email.Mailboxes.get_mailbox(updated_message.mailbox_id)

        if mailbox && mailbox.user_id do
          # Get the new unread count
          new_unread_count = unread_count(updated_message.mailbox_id)

          # Broadcast the unread count update
          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "user:#{mailbox.user_id}",
            {:unread_count_updated, new_unread_count}
          )

          # Clear email notification when email is marked as read
          Elektrine.Notifications.mark_as_read_by_source(
            mailbox.user_id,
            "email",
            updated_message.id
          )
        end

        CacheHooks.with_cache_invalidation({:ok, updated_message},
          user_id: mailbox && mailbox.user_id
        )
        |> maybe_bump_mailbox_email_states(updated_message.mailbox_id)

      error ->
        error
    end
  end

  @doc """
  Marks a message as unread.
  """
  def mark_as_unread(%Message{} = message) do
    result =
      message
      |> Message.unread_changeset()
      |> Repo.update()

    case result do
      {:ok, updated_message} ->
        # Get the mailbox to find the user_id
        mailbox = Elektrine.Email.Mailboxes.get_mailbox(updated_message.mailbox_id)

        if mailbox && mailbox.user_id do
          # Get the new unread count
          new_unread_count = unread_count(updated_message.mailbox_id)

          # Broadcast the unread count update
          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "user:#{mailbox.user_id}",
            {:unread_count_updated, new_unread_count}
          )
        end

        CacheHooks.with_cache_invalidation({:ok, updated_message},
          user_id: mailbox && mailbox.user_id
        )
        |> maybe_bump_mailbox_email_states(updated_message.mailbox_id)

      error ->
        error
    end
  end

  @doc """
  Marks a message as spam.
  """
  def mark_as_spam(%Message{} = message) do
    result =
      message
      |> Message.spam_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    maybe_bump_mailbox_email_states(result, message.mailbox_id)
  end

  @doc """
  Marks a message as not spam.
  """
  def mark_as_not_spam(%Message{} = message) do
    result =
      message
      |> Message.unspam_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    maybe_bump_mailbox_email_states(result, message.mailbox_id)
  end

  @doc """
  Archives a message.
  """
  def archive_message(%Message{} = message) do
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      message
      |> Message.archive_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    # Broadcast unread count update if the message was unread
    if was_unread and match?({:ok, _}, result) do
      broadcast_unread_count_update(mailbox_id)
    end

    maybe_bump_mailbox_email_states(result, mailbox_id)

    result
  end

  @doc """
  Unarchives a message.
  """
  def unarchive_message(%Message{} = message) do
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      message
      |> Message.unarchive_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    # Broadcast unread count update if the message was unread
    if was_unread and match?({:ok, _}, result) do
      broadcast_unread_count_update(mailbox_id)
    end

    maybe_bump_mailbox_email_states(result, mailbox_id)

    result
  end

  @doc """
  Moves a message to trash (soft delete).
  """
  def trash_message(%Message{} = message) do
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      message
      |> Message.trash_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    # Broadcast unread count update if the message was unread
    if was_unread and match?({:ok, _}, result) do
      broadcast_unread_count_update(mailbox_id)
    end

    maybe_bump_mailbox_email_states(result, mailbox_id)

    result
  end

  @doc """
  Restores a message from trash.
  """
  def untrash_message(%Message{} = message) do
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      message
      |> Message.untrash_changeset()
      |> Repo.update()
      |> CacheHooks.with_cache_invalidation()

    # Broadcast unread count update if the message was unread
    if was_unread and match?({:ok, _}, result) do
      broadcast_unread_count_update(mailbox_id)
    end

    maybe_bump_mailbox_email_states(result, mailbox_id)

    result
  end

  @doc """
  Permanently deletes a message (hard delete).
  Can accept either a Message struct or an integer ID.
  """
  def delete_message(%Message{} = message) do
    # Store info before deletion
    was_unread = !message.read
    mailbox_id = message.mailbox_id

    result =
      Multi.new()
      |> Multi.delete(:message, message)
      |> Multi.run(:tombstone, fn _repo, _changes ->
        case JMAP.record_email_destroyed(mailbox_id, message.id, ["Mailbox", "Thread"]) do
          :ok -> {:ok, :recorded}
          other -> other
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{message: deleted_message}} -> {:ok, deleted_message}
        {:error, _step, reason, _changes} -> {:error, reason}
      end

    case result do
      {:ok, deleted_message} ->
        mailbox = Elektrine.Email.Mailboxes.get_mailbox(mailbox_id)

        # Broadcast unread count update if the deleted message was unread
        if was_unread && mailbox && mailbox.user_id do
          # Get the new unread count
          new_unread_count = unread_count(mailbox_id)

          # Broadcast the unread count update
          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "user:#{mailbox.user_id}",
            {:unread_count_updated, new_unread_count}
          )
        end

        # Always broadcast message deletion for IMAP sync (even for read messages)
        if mailbox && mailbox.user_id do
          Phoenix.PubSub.broadcast!(
            Elektrine.PubSub,
            "mailbox:#{mailbox_id}",
            {:message_deleted, deleted_message.id}
          )
        end

        # Invalidate caches after deletion
        user_id = if mailbox, do: mailbox.user_id

        result =
          CacheHooks.with_cache_invalidation(result, user_id: user_id, mailbox_id: mailbox_id)

        result

      error ->
        error
    end
  end

  # Overload for integer message IDs (for POP3 DELE command)
  def delete_message(message_id) when is_integer(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        delete_message(message)
    end
  end

  @doc """
  Deletes a message with mailbox ownership verification (secure version for IMAP).
  Returns {:error, :not_found} if message doesn't belong to the mailbox.
  """
  def delete_message(message_id, mailbox_id)
      when is_integer(message_id) and is_integer(mailbox_id) do
    case get_message(message_id, mailbox_id) do
      nil ->
        {:error, :not_found}

      message ->
        delete_message(message)
    end
  end

  @doc """
  Tracks when a message is opened.
  """
  def track_message_open(%Message{} = message) do
    message
    |> Message.track_open_changeset()
    |> Repo.update()
  end

  @doc """
  Returns the unread message count for a user.
  """
  def user_unread_count(user_id) do
    mailbox = Elektrine.Email.Mailboxes.get_user_mailbox(user_id)

    if mailbox do
      unread_count(mailbox.id)
    else
      0
    end
  end

  @doc """
  Returns the unread message count for a mailbox.
  """
  def unread_count(mailbox_id) do
    started_at = System.monotonic_time(:millisecond)

    count =
      Message
      |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
      |> where([m], m.category not in ["feed", "ledger", "stack"])
      |> where([m], is_nil(m.reply_later_at))
      |> Repo.aggregate(:count)

    emit_db_hot_path(:email_messages, :unread_count, started_at, %{mailbox_id: mailbox_id})
    count
  end

  # Broadcasts an unread count update for a mailbox.
  # Helper function to be called after operations that affect unread status.
  defp broadcast_unread_count_update(mailbox_id) do
    mailbox = Elektrine.Email.Mailboxes.get_mailbox(mailbox_id)

    if mailbox && mailbox.user_id do
      new_unread_count = unread_count(mailbox_id)

      Phoenix.PubSub.broadcast!(
        Elektrine.PubSub,
        "user:#{mailbox.user_id}",
        {:unread_count_updated, new_unread_count}
      )
    end
  end

  @doc """
  Returns the unread feed message count for a mailbox.
  """
  def unread_feed_count(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status))
    |> where(category: "feed")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the unread paper trail message count for a mailbox.
  """
  def unread_ledger_count(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status))
    |> where(category: "ledger")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the unread set aside ("the pile") message count for a mailbox.
  """
  def unread_stack_count(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status))
    |> where(category: "stack")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the unread reply later ("boomerang") message count for a mailbox.
  """
  def unread_reply_later_count(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status))
    |> where([m], not is_nil(m.reply_later_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the unread inbox message count for a mailbox.
  This counts messages that are in the main inbox (not in special categories).
  """
  def unread_inbox_count(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> where([m], is_nil(m.category) or m.category not in ["feed", "ledger", "stack"])
    |> where([m], is_nil(m.reply_later_at))
    |> where([m], is_nil(m.folder_id))
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns all unread counts for a mailbox in a single query.
  This ensures consistency by fetching all counts from the same database snapshot.

  Returns a map with keys: :inbox, :feed, :ledger, :stack, :reply_later
  """
  def get_all_unread_counts(mailbox_id) do
    started_at = System.monotonic_time(:millisecond)

    result =
      Message
      |> where(mailbox_id: ^mailbox_id, read: false, spam: false, archived: false, deleted: false)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
      |> select([m], %{
        inbox:
          fragment(
            "COUNT(*) FILTER (WHERE (category IS NULL OR category NOT IN ('feed', 'ledger', 'stack')) AND reply_later_at IS NULL AND folder_id IS NULL)"
          ),
        feed: fragment("COUNT(*) FILTER (WHERE category = 'feed')"),
        ledger: fragment("COUNT(*) FILTER (WHERE category = 'ledger')"),
        stack: fragment("COUNT(*) FILTER (WHERE category = 'stack')"),
        reply_later: fragment("COUNT(*) FILTER (WHERE reply_later_at IS NOT NULL)")
      })
      |> Repo.one()

    emit_db_hot_path(:email_messages, :get_all_unread_counts, started_at, %{
      mailbox_id: mailbox_id
    })

    result || %{inbox: 0, feed: 0, ledger: 0, stack: 0, reply_later: 0}
  end

  defp emit_db_hot_path(component, operation, started_at, metadata) do
    Events.db_hot_path(
      component,
      operation,
      System.monotonic_time(:millisecond) - started_at,
      metadata
    )
  end

  @doc """
  Updates message flags for IMAP.
  Accepts either a message struct or a message_id integer.
  """
  def update_message_flags(%Message{} = message, updates) do
    update_message_flags(message.id, updates)
  end

  def update_message_flags(message_id, updates) when is_integer(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        changeset = Message.changeset(message, updates)

        mailbox_id = message.mailbox_id
        mailbox = Elektrine.Email.Mailboxes.get_mailbox(mailbox_id)
        user_id = if mailbox, do: mailbox.user_id

        case Repo.update(changeset) do
          {:ok, updated_message} ->
            result =
              CacheHooks.with_cache_invalidation({:ok, updated_message},
                user_id: user_id,
                mailbox_id: mailbox_id
              )

            bump_states_for_update(mailbox_id, updated_message.id, updates)
            result

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Updates message flags with mailbox ownership verification (secure version for IMAP).
  Returns {:error, :access_denied} if message doesn't belong to the mailbox.
  Accepts either a message struct or a message_id integer.
  """
  def update_message_flags(%Message{} = message, mailbox_id, updates) do
    update_message_flags(message.id, mailbox_id, updates)
  end

  def update_message_flags(message_id, mailbox_id, updates)
      when is_integer(message_id) and is_integer(mailbox_id) do
    case get_message(message_id, mailbox_id) do
      nil ->
        {:error, :not_found}

      message ->
        changeset = Message.changeset(message, updates)

        result =
          case Repo.update(changeset) do
            {:ok, updated_message} ->
              # Invalidate caches and broadcast to LiveView
              mailbox = Elektrine.Email.Mailboxes.get_mailbox(mailbox_id)
              user_id = if mailbox, do: mailbox.user_id

              # Clear email notification when message is marked as read via IMAP
              if Map.get(updates, :read) == true && !message.read && user_id do
                Elektrine.Notifications.mark_as_read_by_source(
                  user_id,
                  "email",
                  updated_message.id
                )

                # Broadcast the unread count update
                new_unread_count = unread_count(mailbox_id)

                Phoenix.PubSub.broadcast!(
                  Elektrine.PubSub,
                  "user:#{user_id}",
                  {:unread_count_updated, new_unread_count}
                )
              end

              # Broadcast message update to webmail for IMAP sync
              # This ensures webmail reflects flag changes (read, flagged, deleted, etc.)
              if user_id do
                Phoenix.PubSub.broadcast!(
                  Elektrine.PubSub,
                  "user:#{user_id}",
                  {:message_flags_updated, %{message_id: updated_message.id, updates: updates}}
                )

                # Also broadcast generic refresh event for better compatibility
                Phoenix.PubSub.broadcast!(
                  Elektrine.PubSub,
                  "mailbox:#{mailbox_id}",
                  {:message_updated, updated_message}
                )
              end

              CacheHooks.with_cache_invalidation({:ok, updated_message},
                user_id: user_id,
                mailbox_id: mailbox_id
              )
              |> tap(fn _ -> bump_states_for_update(mailbox_id, updated_message.id, updates) end)

            {:error, changeset} ->
              {:error, changeset}
          end

        result
    end
  end

  @doc """
  Calculate the storage size of a message in bytes.
  Includes subject, body content, and attachments.
  """
  def calculate_message_size(message_attrs) do
    subject_size = byte_size(get_field_value(message_attrs, "subject", :subject) || "")
    text_body_size = byte_size(get_field_value(message_attrs, "text_body", :text_body) || "")
    html_body_size = byte_size(get_field_value(message_attrs, "html_body", :html_body) || "")
    from_size = byte_size(get_field_value(message_attrs, "from", :from) || "")
    to_size = byte_size(get_field_value(message_attrs, "to", :to) || "")
    cc_size = byte_size(get_field_value(message_attrs, "cc", :cc) || "")
    bcc_size = byte_size(get_field_value(message_attrs, "bcc", :bcc) || "")

    # Calculate attachments size
    attachments = get_field_value(message_attrs, "attachments", :attachments) || %{}

    attachments_size =
      if is_map(attachments) do
        attachments
        |> Map.values()
        |> Enum.reduce(0, fn attachment, acc ->
          case attachment do
            %{"size" => size} when is_integer(size) -> acc + size
            %{size: size} when is_integer(size) -> acc + size
            _ -> acc
          end
        end)
      else
        0
      end

    subject_size + text_body_size + html_body_size + from_size + to_size + cc_size + bcc_size +
      attachments_size
  end

  defp normalize_mailbox_id(mailbox_id) when is_integer(mailbox_id), do: mailbox_id

  defp normalize_mailbox_id(mailbox_id) when is_binary(mailbox_id) do
    case Integer.parse(mailbox_id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_mailbox_id(_), do: nil

  defp normalize_threading_fields(attrs) do
    attrs
    |> maybe_put_attr(:message_id, normalize_message_id(get_attr(attrs, :message_id)))
    |> maybe_put_attr(:in_reply_to, normalize_message_id(get_attr(attrs, :in_reply_to)))
    |> maybe_put_attr(:references, normalize_references(get_attr(attrs, :references)))
  end

  defp maybe_build_thread_references(attrs, mailbox_id) when is_integer(mailbox_id) do
    in_reply_to = normalize_message_id(get_attr(attrs, :in_reply_to))
    existing_references = normalize_references(get_attr(attrs, :references))

    cond do
      blank_value?(in_reply_to) ->
        attrs

      !blank_value?(existing_references) ->
        merged_refs =
          existing_references
          |> parse_reference_ids()
          |> Kernel.++([in_reply_to])
          |> Enum.uniq()
          |> Enum.join(" ")

        put_attr(attrs, :references, merged_refs)

      true ->
        parent_refs =
          case load_parent_message_for_threading(mailbox_id, in_reply_to) do
            nil ->
              []

            parent ->
              parent_message_id = normalize_message_id(parent.message_id)
              inherited_refs = parse_reference_ids(parent.references)

              if blank_value?(parent_message_id) do
                inherited_refs
              else
                inherited_refs ++ [parent_message_id]
              end
          end

        merged_refs =
          parent_refs
          |> Kernel.++([in_reply_to])
          |> Enum.reject(&blank_value?/1)
          |> Enum.uniq()
          |> Enum.join(" ")

        if blank_value?(merged_refs) do
          attrs
        else
          put_attr(attrs, :references, merged_refs)
        end
    end
  end

  defp maybe_build_thread_references(attrs, _mailbox_id), do: attrs

  defp maybe_assign_thread(attrs, mailbox_id)
       when is_integer(mailbox_id) and mailbox_id > 0 do
    case get_attr(attrs, :thread_id) do
      thread_id when is_integer(thread_id) and thread_id > 0 ->
        attrs

      _ ->
        case Elektrine.JMAP.assign_thread(attrs, mailbox_id) do
          {:ok, thread_id} when is_integer(thread_id) and thread_id > 0 ->
            put_attr(attrs, :thread_id, thread_id)

          _ ->
            attrs
        end
    end
  end

  defp maybe_assign_thread(attrs, _mailbox_id), do: attrs

  defp load_parent_message_for_threading(mailbox_id, in_reply_to) do
    candidates = message_id_lookup_candidates(in_reply_to)

    if candidates == [] do
      nil
    else
      Message
      |> where([m], m.mailbox_id == ^mailbox_id and m.message_id in ^candidates)
      |> order_by([m], desc: m.inserted_at)
      |> limit(1)
      |> Repo.one()
    end
  end

  defp message_id_lookup_candidates(nil), do: []
  defp message_id_lookup_candidates(""), do: []

  defp message_id_lookup_candidates(message_id) do
    case normalize_message_id(message_id) do
      nil -> []
      normalized -> Enum.uniq([normalized, "<#{normalized}>"])
    end
  end

  defp normalize_message_id(nil), do: nil
  defp normalize_message_id(""), do: nil

  defp normalize_message_id(message_id) when is_binary(message_id) do
    message_id
    |> String.trim()
    |> String.replace(~r/^<|>$/, "")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_message_id(message_id), do: normalize_message_id(to_string(message_id))

  defp normalize_references(nil), do: nil
  defp normalize_references(""), do: nil

  defp normalize_references(references) when is_list(references) do
    references
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&blank_value?/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      refs -> Enum.join(refs, " ")
    end
  end

  defp normalize_references(references) when is_binary(references) do
    references
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&blank_value?/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      refs -> Enum.join(refs, " ")
    end
  end

  defp normalize_references(references), do: normalize_references(to_string(references))

  defp parse_reference_ids(nil), do: []
  defp parse_reference_ids(""), do: []

  defp parse_reference_ids(references) when is_binary(references) do
    references
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.reject(&blank_value?/1)
  end

  defp parse_reference_ids(references) when is_list(references) do
    references
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&blank_value?/1)
  end

  defp parse_reference_ids(_), do: []

  defp truthy?(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    Enum.member?(["true", "1", "yes", "on"], normalized)
  end

  defp truthy?(value), do: value == true

  defp get_attr(attrs, atom_key) when is_map(attrs) and is_atom(atom_key) do
    Map.get(attrs, atom_key) || Map.get(attrs, Atom.to_string(atom_key))
  end

  defp put_attr(attrs, atom_key, value) when is_map(attrs) and is_atom(atom_key) do
    string_key = Atom.to_string(atom_key)

    cond do
      Map.has_key?(attrs, atom_key) ->
        Map.put(attrs, atom_key, value)

      Map.has_key?(attrs, string_key) ->
        Map.put(attrs, string_key, value)

      Enum.any?(Map.keys(attrs), &is_atom/1) ->
        Map.put(attrs, atom_key, value)

      true ->
        Map.put(attrs, string_key, value)
    end
  end

  defp maybe_put_attr(attrs, atom_key, value) do
    if blank_value?(value) do
      attrs
    else
      put_attr(attrs, atom_key, value)
    end
  end

  defp blank_value?(value) when is_nil(value), do: true
  defp blank_value?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp blank_value?(_), do: false

  # Helper function to safely get field values from string or atom keys
  defp get_field_value(attrs, string_key, atom_key) do
    Map.get(attrs, string_key) || Map.get(attrs, atom_key)
  end

  defp maybe_bump_mailbox_email_states({:ok, %Message{id: message_id} = result}, mailbox_id)
       when is_integer(mailbox_id) do
    bump_mailbox_email_states(mailbox_id, message_id)
    {:ok, result}
  end

  defp maybe_bump_mailbox_email_states(result, _mailbox_id), do: result

  defp bump_states_for_update(mailbox_id, message_id, attrs)
       when is_integer(mailbox_id) and is_integer(message_id) and is_map(attrs) do
    entity_types =
      []
      |> maybe_add_mailbox_state(attrs)
      |> maybe_add_thread_state(attrs)
      |> Enum.uniq()

    JMAP.record_email_updated(mailbox_id, message_id, entity_types)
  end

  defp bump_states_for_update(_mailbox_id, _message_id, _attrs), do: :ok

  defp maybe_add_mailbox_state(entity_types, attrs) do
    if Enum.any?(
         ~w(read spam archived deleted category status folder_id),
         &attrs_has_key?(attrs, &1)
       ) do
      ["Mailbox" | entity_types]
    else
      entity_types
    end
  end

  defp maybe_add_thread_state(entity_types, attrs) do
    if attrs_has_key?(attrs, "thread_id") do
      ["Thread" | entity_types]
    else
      entity_types
    end
  end

  defp attrs_has_key?(attrs, key) when is_binary(key) do
    Map.has_key?(attrs, key) or
      try do
        Map.has_key?(attrs, String.to_existing_atom(key))
      rescue
        ArgumentError -> false
      end
  end

  defp bump_message_creation_states(mailbox_id, message_id)
       when is_integer(mailbox_id) and is_integer(message_id) do
    JMAP.record_email_created(mailbox_id, message_id, ["Mailbox", "Thread"])
  end

  defp bump_message_creation_states(_mailbox_id, _message_id), do: :ok

  defp bump_mailbox_email_states(mailbox_id, message_id)
       when is_integer(mailbox_id) and is_integer(message_id) do
    JMAP.record_email_updated(mailbox_id, message_id, ["Mailbox"])
  end

  defp bump_mailbox_email_states(_mailbox_id, _message_id), do: :ok
end
