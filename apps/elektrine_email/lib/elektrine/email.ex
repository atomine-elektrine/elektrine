defmodule Elektrine.Email do
  @moduledoc """
  The Email context.
  This context handles all email-related functionality like managing mailboxes,
  sending/receiving emails, and storing/retrieving email messages.

  This module serves as the main public API and delegates to specialized sub-contexts:
  - Elektrine.Email.Mailboxes - Mailbox management
  - Elektrine.Email.Messages - Message CRUD and queries
  - Elektrine.Email.Folders - Folder operations and categories
  - Elektrine.Email.Search - Message search functionality
  - Elektrine.Email.Processing - Categorization and processing
  - Elektrine.Email.Aliases - Email alias management
  - Elektrine.Email.BlockedSenders - Blocked sender management
  - Elektrine.Email.SafeSenders - Safe sender/whitelist management
  - Elektrine.Email.Filters - Email filter/rule management
  - Elektrine.Email.AutoReplies - Auto-reply/vacation responder
  - Elektrine.Email.Templates - Email template management
  - Elektrine.Email.CustomFolders - Custom folder management
  - Elektrine.Email.Labels - Label/tag management
  - Elektrine.Email.Exports - Email export/backup
  """

  # Delegate mailbox functions to Mailboxes module
  defdelegate get_user_mailbox(user_id), to: Elektrine.Email.Mailboxes
  defdelegate get_user_mailboxes(user_id), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox_admin(id), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox_internal(id), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox_by_email(email), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox_by_username(username), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox(id, user_id), to: Elektrine.Email.Mailboxes
  defdelegate create_mailbox(user_or_params), to: Elektrine.Email.Mailboxes
  defdelegate ensure_user_has_mailbox(user), to: Elektrine.Email.Mailboxes
  defdelegate list_mailboxes(user_id), to: Elektrine.Email.Mailboxes
  defdelegate list_all_mailboxes(), to: Elektrine.Email.Mailboxes
  defdelegate update_mailbox(mailbox, attrs), to: Elektrine.Email.Mailboxes
  defdelegate update_mailbox_email(mailbox, new_email), to: Elektrine.Email.Mailboxes

  defdelegate transition_mailbox_for_username_change(user, old_mailbox, new_email),
    to: Elektrine.Email.Mailboxes

  defdelegate delete_mailbox(mailbox), to: Elektrine.Email.Mailboxes
  defdelegate update_mailbox_forwarding(mailbox, attrs), to: Elektrine.Email.Mailboxes
  defdelegate change_mailbox_forwarding(mailbox, attrs \\ %{}), to: Elektrine.Email.Mailboxes
  defdelegate get_mailbox_forward_target(mailbox), to: Elektrine.Email.Mailboxes

  # Delegate message functions to Messages module
  defdelegate get_message_admin(id), to: Elektrine.Email.Messages
  defdelegate get_message_internal(id), to: Elektrine.Email.Messages
  defdelegate get_message(id, mailbox_id), to: Elektrine.Email.Messages
  defdelegate get_message_by_hash(hash), to: Elektrine.Email.Messages
  defdelegate get_message_by_id(message_id, mailbox_id), to: Elektrine.Email.Messages
  defdelegate get_user_message(message_id, user_id), to: Elektrine.Email.Messages
  defdelegate list_user_messages(user_id, limit \\ 50, offset \\ 0), to: Elektrine.Email.Messages

  defdelegate list_user_messages_secure(user_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Messages

  defdelegate list_messages(mailbox_id, limit \\ 50, offset \\ 0), to: Elektrine.Email.Messages

  defdelegate list_inbox_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Messages

  defdelegate list_spam_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Messages

  defdelegate list_archived_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Messages

  defdelegate list_user_unread_messages(user_id), to: Elektrine.Email.Messages
  defdelegate list_unread_messages(mailbox_id), to: Elektrine.Email.Messages
  defdelegate create_message(attrs \\ %{}), to: Elektrine.Email.Messages
  defdelegate update_message(message, attrs), to: Elektrine.Email.Messages
  defdelegate save_draft(attrs, draft_id \\ nil), to: Elektrine.Email.Messages
  defdelegate get_draft(draft_id, mailbox_id), to: Elektrine.Email.Messages
  defdelegate delete_draft(draft_id, mailbox_id), to: Elektrine.Email.Messages

  defdelegate update_message_attachments(message, attachments, has_attachments),
    to: Elektrine.Email.Messages

  defdelegate mark_as_read(message), to: Elektrine.Email.Messages
  defdelegate mark_as_unread(message), to: Elektrine.Email.Messages
  defdelegate mark_as_spam(message), to: Elektrine.Email.Messages
  defdelegate mark_as_not_spam(message), to: Elektrine.Email.Messages
  defdelegate archive_message(message), to: Elektrine.Email.Messages
  defdelegate unarchive_message(message), to: Elektrine.Email.Messages
  defdelegate trash_message(message), to: Elektrine.Email.Messages
  defdelegate untrash_message(message), to: Elektrine.Email.Messages
  defdelegate delete_message(message_or_id), to: Elektrine.Email.Messages
  defdelegate delete_message(message_id, mailbox_id), to: Elektrine.Email.Messages
  defdelegate track_message_open(message), to: Elektrine.Email.Messages
  defdelegate user_unread_count(user_id), to: Elektrine.Email.Messages
  defdelegate unread_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate unread_feed_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate unread_ledger_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate unread_stack_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate unread_reply_later_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate unread_inbox_count(mailbox_id), to: Elektrine.Email.Messages
  defdelegate get_all_unread_counts(mailbox_id), to: Elektrine.Email.Messages
  defdelegate update_message_flags(message_id, updates), to: Elektrine.Email.Messages
  defdelegate update_message_flags(message_id, mailbox_id, updates), to: Elektrine.Email.Messages
  defdelegate calculate_message_size(message_attrs), to: Elektrine.Email.Messages

  # Delegate folder/category functions to Folders module
  defdelegate list_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_inbox_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_spam_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_trash_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_archived_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_sent_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_drafts_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate drafts_count(mailbox_id), to: Elektrine.Email.Folders

  defdelegate list_unread_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_read_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_feed_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Folders

  defdelegate list_feed_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_ledger_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Folders

  defdelegate list_ledger_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_stack_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Folders

  defdelegate list_stack_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_reply_later_messages(mailbox_id, limit \\ 50, offset \\ 0),
    to: Elektrine.Email.Folders

  defdelegate list_reply_later_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Folders

  defdelegate list_all_inbox_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_feed_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_ledger_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_stack_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_reply_later_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_sent_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate list_all_spam_messages(mailbox_id), to: Elektrine.Email.Folders
  defdelegate stack_message(message, reason \\ nil), to: Elektrine.Email.Folders
  defdelegate unstack_message(message), to: Elektrine.Email.Folders
  defdelegate move_to_digest(message), to: Elektrine.Email.Folders
  defdelegate move_to_ledger(message), to: Elektrine.Email.Folders

  defdelegate reply_later_message(message, reply_at, reminder \\ false),
    to: Elektrine.Email.Folders

  defdelegate clear_reply_later(message), to: Elektrine.Email.Folders
  defdelegate list_messages_for_imap(mailbox_id, folder), to: Elektrine.Email.Folders

  defdelegate list_messages_for_imap_custom_folder(mailbox_id, folder_id),
    to: Elektrine.Email.Folders

  defdelegate list_messages_for_pop3(mailbox_id), to: Elektrine.Email.Folders

  # Delegate search functions to Search module
  defdelegate search_messages(mailbox_id, query, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Search

  defdelegate get_unique_recipient_domains(), to: Elektrine.Email.Search

  defdelegate get_unique_recipient_domains_paginated(page \\ 1, per_page \\ 50),
    to: Elektrine.Email.Search

  # Delegate processing functions to Processing module
  defdelegate categorize_message(message_attrs), to: Elektrine.Email.Processing
  defdelegate process_uncategorized_messages(), to: Elektrine.Email.Processing
  defdelegate recategorize_messages(mailbox_id), to: Elektrine.Email.Processing

  # Delegate alias functions to Aliases module
  defdelegate list_aliases(user_id), to: Elektrine.Email.Aliases
  defdelegate get_alias(id, user_id), to: Elektrine.Email.Aliases
  defdelegate get_alias_by_email(alias_email), to: Elektrine.Email.Aliases
  defdelegate create_alias(attrs \\ %{}), to: Elektrine.Email.Aliases
  defdelegate update_alias(alias, attrs), to: Elektrine.Email.Aliases
  defdelegate delete_alias(alias), to: Elektrine.Email.Aliases
  defdelegate change_alias(alias, attrs \\ %{}), to: Elektrine.Email.Aliases
  defdelegate resolve_alias(email), to: Elektrine.Email.Aliases

  @doc """
  Verifies that a user owns or has access to a specific email address.
  This prevents unauthorized email access by validating ownership.

  Checks in order:
  1. User's main mailbox (user@elektrine.com or user@z.org)
  2. User's email aliases
  3. Cross-domain matching (elektrine.com <-> z.org)
  """
  def verify_email_ownership(email_address, user_id)
      when is_binary(email_address) and is_integer(user_id) do
    clean_email = String.downcase(String.trim(email_address))

    # Check 1: User's main mailbox
    case Elektrine.Email.Mailboxes.get_user_mailbox(user_id) do
      %Elektrine.Email.Mailbox{email: mailbox_email} ->
        if String.downcase(mailbox_email) == clean_email do
          {:ok, :main_mailbox}
        else
          check_alias_ownership(clean_email, user_id)
        end

      nil ->
        check_alias_ownership(clean_email, user_id)
    end
  end

  def verify_email_ownership(_, _), do: {:error, :invalid_params}

  # Check if user owns the email through an alias
  defp check_alias_ownership(email_address, user_id) do
    # Check 2: User's email aliases
    case Elektrine.Email.Aliases.get_alias_by_email(email_address) do
      %Elektrine.Email.Alias{user_id: ^user_id} ->
        # Accept both enabled and disabled aliases for email routing
        {:ok, :alias}

      %Elektrine.Email.Alias{user_id: other_user_id} ->
        {:error, {:owned_by_other_user, other_user_id}}

      nil ->
        # Check 3: Cross-domain matching (user@elektrine.com <-> user@z.org)
        check_cross_domain_ownership(email_address, user_id)
    end
  end

  # Check cross-domain ownership for supported domains
  defp check_cross_domain_ownership(email_address, user_id) do
    case String.split(email_address, "@") do
      [username, domain] ->
        supported_domains =
          Application.get_env(:elektrine, :email)[:supported_domains] ||
            ["elektrine.com", "z.org"]

        if domain in supported_domains do
          # Check if user's username matches the local part
          user = Elektrine.Accounts.get_user!(user_id)

          if String.downcase(user.username) == String.downcase(username) do
            {:ok, :cross_domain_match}
          else
            # Not the user's main email - this is fine, they might have aliases
            {:error, :not_main_email}
          end
        else
          {:error, :unsupported_domain}
        end

      _ ->
        {:error, :invalid_email_format}
    end
  end

  @doc """
  Extracts email address from a string that may contain display name.
  Examples:
  - "user@example.com" -> "user@example.com"
  - "John Doe <user@example.com>" -> "user@example.com"
  - "\"Doe, John\" <user@example.com>" -> "user@example.com"
  """
  def extract_email_address(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  def extract_email_address(nil), do: nil

  @doc """
  Normalizes email addresses by removing plus addressing.
  Converts "user+tag@domain.com" to "user@domain.com".
  Returns the original email if no plus addressing is found.
  """
  def normalize_plus_address(email) when is_binary(email) do
    case String.split(email, "@") do
      [local_part, domain] ->
        # Remove everything after + in the local part
        normalized_local =
          case String.split(local_part, "+") do
            [base | _] -> base
            [] -> local_part
          end

        normalized_local <> "@" <> domain

      _ ->
        # Invalid email format, return as is
        email
    end
  end

  def normalize_plus_address(nil), do: nil

  # Delegate blocked sender functions to BlockedSenders module
  defdelegate list_blocked_senders(user_id), to: Elektrine.Email.BlockedSenders
  defdelegate get_blocked_sender(id, user_id), to: Elektrine.Email.BlockedSenders
  defdelegate create_blocked_sender(attrs), to: Elektrine.Email.BlockedSenders
  defdelegate block_email(user_id, email, reason \\ nil), to: Elektrine.Email.BlockedSenders
  defdelegate block_domain(user_id, domain, reason \\ nil), to: Elektrine.Email.BlockedSenders
  defdelegate update_blocked_sender(blocked_sender, attrs), to: Elektrine.Email.BlockedSenders
  defdelegate delete_blocked_sender(blocked_sender), to: Elektrine.Email.BlockedSenders
  defdelegate unblock_email(user_id, email), to: Elektrine.Email.BlockedSenders
  defdelegate unblock_domain(user_id, domain), to: Elektrine.Email.BlockedSenders
  defdelegate is_blocked?(user_id, from_email), to: Elektrine.Email.BlockedSenders

  defdelegate change_blocked_sender(blocked_sender, attrs \\ %{}),
    to: Elektrine.Email.BlockedSenders

  # Delegate safe sender functions to SafeSenders module
  defdelegate list_safe_senders(user_id), to: Elektrine.Email.SafeSenders
  defdelegate get_safe_sender(id, user_id), to: Elektrine.Email.SafeSenders
  defdelegate create_safe_sender(attrs), to: Elektrine.Email.SafeSenders
  defdelegate add_safe_email(user_id, email), to: Elektrine.Email.SafeSenders
  defdelegate add_safe_domain(user_id, domain), to: Elektrine.Email.SafeSenders
  defdelegate update_safe_sender(safe_sender, attrs), to: Elektrine.Email.SafeSenders
  defdelegate delete_safe_sender(safe_sender), to: Elektrine.Email.SafeSenders
  defdelegate remove_safe_email(user_id, email), to: Elektrine.Email.SafeSenders
  defdelegate remove_safe_domain(user_id, domain), to: Elektrine.Email.SafeSenders
  defdelegate is_safe?(user_id, from_email), to: Elektrine.Email.SafeSenders
  defdelegate change_safe_sender(safe_sender, attrs \\ %{}), to: Elektrine.Email.SafeSenders

  # Delegate filter functions to Filters module
  defdelegate list_filters(user_id), to: Elektrine.Email.Filters
  defdelegate list_enabled_filters(user_id), to: Elektrine.Email.Filters
  defdelegate get_filter(id, user_id), to: Elektrine.Email.Filters
  defdelegate create_filter(attrs), to: Elektrine.Email.Filters
  defdelegate update_filter(filter, attrs), to: Elektrine.Email.Filters
  defdelegate delete_filter(filter), to: Elektrine.Email.Filters
  defdelegate toggle_filter(filter), to: Elektrine.Email.Filters
  defdelegate change_filter(filter, attrs \\ %{}), to: Elektrine.Email.Filters
  defdelegate apply_filters(user_id, message), to: Elektrine.Email.Filters
  defdelegate execute_actions(message, actions), to: Elektrine.Email.Filters

  # Delegate auto-reply functions to AutoReplies module
  defdelegate get_auto_reply(user_id), to: Elektrine.Email.AutoReplies
  defdelegate upsert_auto_reply(user_id, attrs), to: Elektrine.Email.AutoReplies
  defdelegate enable_auto_reply(user_id), to: Elektrine.Email.AutoReplies
  defdelegate disable_auto_reply(user_id), to: Elektrine.Email.AutoReplies
  defdelegate delete_auto_reply(user_id), to: Elektrine.Email.AutoReplies
  defdelegate change_auto_reply(auto_reply, attrs \\ %{}), to: Elektrine.Email.AutoReplies
  defdelegate process_auto_reply(message, user_id), to: Elektrine.Email.AutoReplies

  # Delegate template functions to Templates module
  defdelegate list_templates(user_id), to: Elektrine.Email.Templates
  defdelegate get_template(id, user_id), to: Elektrine.Email.Templates
  defdelegate get_template_by_name(name, user_id), to: Elektrine.Email.Templates
  defdelegate create_template(attrs), to: Elektrine.Email.Templates
  defdelegate update_template(template, attrs), to: Elektrine.Email.Templates
  defdelegate delete_template(template), to: Elektrine.Email.Templates
  defdelegate change_template(template, attrs \\ %{}), to: Elektrine.Email.Templates
  defdelegate count_templates(user_id), to: Elektrine.Email.Templates
  defdelegate duplicate_template(template, new_name), to: Elektrine.Email.Templates

  # Delegate custom folder functions to CustomFolders module
  defdelegate list_custom_folders(user_id), to: Elektrine.Email.CustomFolders, as: :list_folders
  defdelegate list_root_folders(user_id), to: Elektrine.Email.CustomFolders
  defdelegate get_custom_folder(id, user_id), to: Elektrine.Email.CustomFolders, as: :get_folder
  defdelegate get_folder_with_children(id, user_id), to: Elektrine.Email.CustomFolders
  defdelegate create_custom_folder(attrs), to: Elektrine.Email.CustomFolders, as: :create_folder

  defdelegate update_custom_folder(folder, attrs),
    to: Elektrine.Email.CustomFolders,
    as: :update_folder

  defdelegate delete_custom_folder(folder), to: Elektrine.Email.CustomFolders, as: :delete_folder

  defdelegate change_custom_folder(folder, attrs \\ %{}),
    to: Elektrine.Email.CustomFolders,
    as: :change_folder

  defdelegate count_custom_folders(user_id), to: Elektrine.Email.CustomFolders, as: :count_folders
  defdelegate move_message_to_folder(message_id, folder_id), to: Elektrine.Email.CustomFolders

  defdelegate list_folder_messages(folder_id, user_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.CustomFolders

  defdelegate get_folder_tree(user_id), to: Elektrine.Email.CustomFolders

  # Delegate label functions to Labels module
  defdelegate list_labels(user_id), to: Elektrine.Email.Labels
  defdelegate get_label(id, user_id), to: Elektrine.Email.Labels
  defdelegate get_label_by_name(name, user_id), to: Elektrine.Email.Labels
  defdelegate create_label(attrs), to: Elektrine.Email.Labels
  defdelegate update_label(label, attrs), to: Elektrine.Email.Labels
  defdelegate delete_label(label), to: Elektrine.Email.Labels
  defdelegate change_label(label, attrs \\ %{}), to: Elektrine.Email.Labels
  defdelegate count_labels(user_id), to: Elektrine.Email.Labels
  defdelegate add_label_to_message(message_id, label_id), to: Elektrine.Email.Labels
  defdelegate remove_label_from_message(message_id, label_id), to: Elektrine.Email.Labels
  defdelegate get_message_labels(message_id, user_id), to: Elektrine.Email.Labels

  defdelegate list_labeled_messages(label_id, user_id, page \\ 1, per_page \\ 20),
    to: Elektrine.Email.Labels

  defdelegate set_message_labels(message_id, label_ids), to: Elektrine.Email.Labels

  # Delegate export functions to Exports module
  defdelegate list_exports(user_id), to: Elektrine.Email.Exports
  defdelegate get_export(id, user_id), to: Elektrine.Email.Exports
  defdelegate create_export(attrs), to: Elektrine.Email.Exports
  defdelegate start_export(user_id, format \\ "mbox", filters \\ %{}), to: Elektrine.Email.Exports
  defdelegate process_export(export), to: Elektrine.Email.Exports
  defdelegate delete_export(export), to: Elektrine.Email.Exports
  defdelegate get_download_path(export), to: Elektrine.Email.Exports
end
