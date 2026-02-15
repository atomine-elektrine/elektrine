defmodule Mix.Tasks.Elektrine.CleanupDuplicateMailboxes do
  use Mix.Task
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.Mailbox

  @shortdoc "Find and optionally clean up duplicate mailboxes"

  def run(args) do
    Mix.Task.run("app.start")

    action = if "--fix" in args, do: :fix, else: :report

    IO.puts("\n🔍 Searching for duplicate mailboxes...\n")

    # Find all mailboxes grouped by lowercase email
    mailboxes =
      Mailbox
      |> preload(:user)
      |> Repo.all()

    # Group by lowercase email
    grouped =
      mailboxes
      |> Enum.group_by(&String.downcase(&1.email))
      |> Enum.filter(fn {_email, boxes} -> length(boxes) > 1 end)

    if Enum.empty?(grouped) do
      IO.puts("✅ No duplicate mailboxes found!")
    else
      IO.puts("⚠️  Found #{length(grouped)} email addresses with duplicate mailboxes:\n")

      Enum.each(grouped, fn {email, boxes} ->
        IO.puts("📧 Email: #{email}")
        IO.puts("   Found #{length(boxes)} mailboxes:")

        Enum.each(boxes, fn box ->
          user_info =
            if box.user do
              "User: #{box.user.username} (ID: #{box.user.id})"
            else
              "User: (no user associated)"
            end

          message_count =
            Elektrine.Email.Message
            |> where([m], m.mailbox_id == ^box.id)
            |> Repo.aggregate(:count, :id)

          IO.puts("   - Mailbox ID: #{box.id}, #{user_info}")
          IO.puts("     Created: #{box.inserted_at}")
          IO.puts("     Messages: #{message_count}")
          IO.puts("     Email in DB: #{box.email} (note case)")
        end)

        if action == :fix do
          IO.puts("\n   🔧 Fixing duplicates...")
          fix_duplicates(boxes)
        end

        IO.puts("")
      end)

      if action == :report do
        IO.puts(
          "\n💡 To fix these duplicates, run: mix elektrine.cleanup_duplicate_mailboxes --fix"
        )

        IO.puts(
          "   This will keep the mailbox with the most messages and merge the others into it."
        )
      end
    end
  end

  defp fix_duplicates(boxes) do
    # Sort by message count (descending) to keep the one with most messages
    sorted_boxes =
      Enum.sort_by(
        boxes,
        fn box ->
          Elektrine.Email.Message
          |> where([m], m.mailbox_id == ^box.id)
          |> Repo.aggregate(:count, :id)
        end,
        :desc
      )

    [keep | to_merge] = sorted_boxes

    if Enum.empty?(to_merge) do
      IO.puts("   Nothing to merge")
    else
      IO.puts("   Keeping mailbox ID: #{keep.id} (has the most messages)")

      Enum.each(to_merge, fn box ->
        message_count =
          Elektrine.Email.Message
          |> where([m], m.mailbox_id == ^box.id)
          |> Repo.aggregate(:count, :id)

        if message_count > 0 do
          IO.puts(
            "   Merging #{message_count} messages from mailbox ID: #{box.id} to mailbox ID: #{keep.id}"
          )

          # Update all messages to point to the kept mailbox
          Elektrine.Email.Message
          |> where([m], m.mailbox_id == ^box.id)
          |> Repo.update_all(set: [mailbox_id: keep.id])
        end

        # Delete the duplicate mailbox
        IO.puts("   Deleting duplicate mailbox ID: #{box.id}")
        Repo.delete!(box)
      end)

      IO.puts("   ✅ Duplicates merged successfully!")
    end
  end
end
