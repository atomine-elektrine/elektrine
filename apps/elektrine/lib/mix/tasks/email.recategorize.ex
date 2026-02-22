defmodule Mix.Tasks.Email.Recategorize do
  @moduledoc """
  Re-categorizes existing messages using updated categorization rules.

  Usage:
    mix email.recategorize                    # Recategorize all mailboxes
    mix email.recategorize --user-id=123     # Recategorize specific user's mailbox
    mix email.recategorize --mailbox-id=456  # Recategorize specific mailbox
    mix email.recategorize --dry-run         # Show what would be changed without applying
  """

  use Mix.Task

  alias Elektrine.Email

  @shortdoc "Re-categorizes existing messages using updated categorization rules"

  def run(args) do
    # Start the application
    Application.ensure_all_started(:elektrine)

    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [
          user_id: :integer,
          mailbox_id: :integer,
          dry_run: :boolean,
          help: :boolean
        ]
      )

    if opts[:help] do
      print_help()
    else
      recategorize(opts)
    end
  end

  defp recategorize(opts) do
    dry_run = opts[:dry_run] || false

    mailbox_ids =
      cond do
        opts[:mailbox_id] ->
          [opts[:mailbox_id]]

        opts[:user_id] ->
          case Email.get_user_mailbox(opts[:user_id]) do
            nil ->
              Mix.shell().error("No mailbox found for user ID #{opts[:user_id]}")
              []

            mailbox ->
              [mailbox.id]
          end

        true ->
          # Get all mailbox IDs
          Email.list_all_mailboxes()
          |> Enum.map(& &1.id)
      end

    if Enum.empty?(mailbox_ids) do
      Mix.shell().error("No mailboxes found to process")
    else
      process_mailboxes(mailbox_ids, dry_run)
    end
  end

  defp process_mailboxes(mailbox_ids, dry_run) do
    Mix.shell().info(
      "#{if dry_run, do: "DRY RUN: ", else: ""}Processing #{length(mailbox_ids)} mailbox(es)..."
    )

    {total_processed, total_changed} =
      Enum.reduce(mailbox_ids, {0, 0}, fn mailbox_id, {acc_processed, acc_changed} ->
        Mix.shell().info("Processing mailbox #{mailbox_id}...")

        {processed, changed} =
          if dry_run do
            dry_run_recategorize(mailbox_id)
          else
            Email.recategorize_messages(mailbox_id)
          end

        Mix.shell().info("  Processed: #{processed}, Changed: #{changed}")
        {acc_processed + processed, acc_changed + changed}
      end)

    Mix.shell().info("\n#{if dry_run, do: "DRY RUN ", else: ""}SUMMARY:")
    Mix.shell().info("Total messages processed: #{total_processed}")
    Mix.shell().info("Total messages changed: #{total_changed}")

    if dry_run do
      Mix.shell().info("\nRun without --dry-run to apply these changes.")
    else
      Mix.shell().info("\nRecategorization complete!")

      # Invalidate caches for all affected mailboxes
      Mix.shell().info("Clearing caches...")

      Enum.each(mailbox_ids, fn mailbox_id ->
        case Email.get_mailbox_internal(mailbox_id) do
          nil ->
            :ok

          mailbox ->
            if mailbox.user_id do
              Elektrine.Email.Cached.invalidate_message_caches(mailbox_id, mailbox.user_id)
            end
        end
      end)

      Mix.shell().info("Cache clearing complete!")
    end
  end

  defp dry_run_recategorize(mailbox_id) do
    # Get all messages
    messages =
      Email.list_messages(mailbox_id, 10_000, 0)
      # Skip spam messages
      |> Enum.reject(& &1.spam)

    processed = length(messages)

    changed =
      Enum.count(messages, fn message ->
        # Create message attributes for categorization
        message_attrs = %{
          "subject" => message.subject,
          "from" => message.from,
          "text_body" => message.text_body,
          "html_body" => message.html_body
        }

        # Apply categorization
        categorized_attrs = Email.categorize_message(message_attrs)

        # Check if anything would change
        would_change_category = categorized_attrs["category"] != message.category

        would_change_receipt =
          Map.get(categorized_attrs, "is_receipt", false) != message.is_receipt

        would_change_newsletter =
          Map.get(categorized_attrs, "is_newsletter", false) != message.is_newsletter

        would_change_notification =
          Map.get(categorized_attrs, "is_notification", false) != message.is_notification

        if would_change_category or would_change_receipt or would_change_newsletter or
             would_change_notification do
          Mix.shell().info("    Would change: #{message.subject}")

          Mix.shell().info(
            "      From: #{message.category || "inbox"} -> #{categorized_attrs["category"] || "inbox"}"
          )

          true
        else
          false
        end
      end)

    {processed, changed}
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
