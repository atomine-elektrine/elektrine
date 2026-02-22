defmodule Mix.Tasks.Elektrine.RecategorizeEmails do
  @moduledoc """
  Recategorizes all email messages using the updated detection logic.

  Usage:
    mix elektrine.recategorize_emails [--mailbox-id MAILBOX_ID]

  Options:
    --mailbox-id    Recategorize messages for a specific mailbox only
    --dry-run       Show what would change without making updates
  """

  use Mix.Task
  alias Elektrine.{Email, Repo}
  alias Elektrine.Email.Mailbox

  @shortdoc "Recategorize email messages with updated detection logic"
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [mailbox_id: :integer, dry_run: :boolean],
        aliases: [m: :mailbox_id, d: :dry_run]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    mailbox_id = Keyword.get(opts, :mailbox_id)

    if mailbox_id do
      IO.puts("Recategorizing messages for mailbox #{mailbox_id}...")
      recategorize_mailbox(mailbox_id, dry_run)
    else
      IO.puts("Recategorizing all messages...")
      recategorize_all_mailboxes(dry_run)
    end

    IO.puts("\nRecategorization complete!")
  end

  defp recategorize_all_mailboxes(dry_run) do
    mailboxes = Repo.all(Mailbox)

    {total_processed, total_changed} =
      Enum.reduce(mailboxes, {0, 0}, fn mailbox, {acc_processed, acc_changed} ->
        IO.puts("\nProcessing mailbox: #{mailbox.email} (ID: #{mailbox.id})")
        {processed, changed} = recategorize_mailbox(mailbox.id, dry_run)
        {acc_processed + processed, acc_changed + changed}
      end)

    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Total messages processed: #{total_processed}")
    IO.puts("Total messages #{if dry_run, do: "would be ", else: ""}changed: #{total_changed}")
  end

  defp recategorize_mailbox(mailbox_id, dry_run) do
    if dry_run do
      {processed, changed} = Email.recategorize_messages(mailbox_id)
      IO.puts("  Would update #{changed} out of #{processed} messages")
      {processed, changed}
    else
      {processed, changed} = Email.recategorize_messages(mailbox_id)
      IO.puts("  Updated #{changed} out of #{processed} messages")
      {processed, changed}
    end
  end
end
