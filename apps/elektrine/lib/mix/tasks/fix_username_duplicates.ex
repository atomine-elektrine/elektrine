defmodule Mix.Tasks.Elektrine.FixUsernameDuplicates do
  use Mix.Task
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Accounts.User
  alias Elektrine.Email.Mailbox

  @shortdoc "Find and fix username duplicates (case-insensitive)"

  def run(args) do
    Mix.Task.run("app.start")

    action =
      cond do
        "--fix" in args -> :fix
        "--report" in args -> :report
        true -> :report
      end

    IO.puts("\n🔍 Checking for username duplicates (case-insensitive)...\n")

    # Find all usernames that have case-only duplicates
    duplicates =
      User
      |> select([u], %{
        username: u.username,
        username_lower: fragment("lower(?)", u.username),
        id: u.id,
        inserted_at: u.inserted_at,
        last_login: u.last_login_at,
        banned: u.banned
      })
      |> Repo.all()
      |> Enum.group_by(& &1.username_lower)
      |> Enum.filter(fn {_username_lower, users} -> length(users) > 1 end)

    if Enum.empty?(duplicates) do
      IO.puts("✅ No username duplicates found!\n")

      if action == :report do
        IO.puts("You can now safely add a case-insensitive unique index:")
        IO.puts("CREATE UNIQUE INDEX users_username_ci_index ON users (lower(username));")
      end
    else
      IO.puts("⚠️  Found #{length(duplicates)} usernames with case-only duplicates:\n")

      Enum.each(duplicates, fn {username_lower, users} ->
        IO.puts("📝 Username (lowercase): #{username_lower}")
        IO.puts("   Found #{length(users)} variations:")

        sorted_users = Enum.sort_by(users, & &1.inserted_at)

        Enum.each(sorted_users, fn user ->
          # Get mailbox info
          mailbox = Repo.one(from m in Mailbox, where: m.user_id == ^user.id, limit: 1)

          message_count =
            if mailbox do
              Repo.one(
                from m in Elektrine.Email.Message,
                  where: m.mailbox_id == ^mailbox.id,
                  select: count(m.id)
              ) || 0
            else
              0
            end

          status =
            cond do
              user.banned -> "🚫 BANNED"
              user.last_login -> "✅ Active"
              true -> "👻 Never logged in"
            end

          IO.puts("   - ID: #{user.id}, Username: \"#{user.username}\" #{status}")
          IO.puts("     Registered: #{Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}")

          if user.last_login do
            IO.puts("     Last login: #{Calendar.strftime(user.last_login, "%Y-%m-%d %H:%M")}")
          end

          IO.puts("     Email messages: #{message_count}")
        end)

        if action == :fix do
          IO.puts("\n   🔧 Recommended action:")
          # The first registered user should keep their username
          [keep | to_rename] = sorted_users

          IO.puts("   Keep: #{keep.username} (ID: #{keep.id}) - registered first")

          Enum.each(to_rename, fn user ->
            suggested_new = suggest_new_username(user.username, username_lower)
            IO.puts("   Rename: #{user.username} (ID: #{user.id}) -> #{suggested_new}")
          end)

          if confirm("\n   Apply these changes?") do
            apply_username_fixes(keep, to_rename, username_lower)
          end
        end

        IO.puts("")
      end)

      if action == :report do
        IO.puts("\n💡 To fix these duplicates automatically, run:")
        IO.puts("   mix elektrine.fix_username_duplicates --fix")
        IO.puts("\n⚠️  Manual resolution may be needed for complex cases.")
      end
    end
  end

  defp suggest_new_username(_original, base) do
    # Try adding numbers until we find a unique username
    Enum.find(1..999, fn n ->
      candidate = "#{base}#{n}"
      !Repo.exists?(from u in User, where: fragment("lower(?)", u.username) == ^candidate)
    end)
    |> case do
      nil -> "#{base}_#{:rand.uniform(9999)}"
      n -> "#{base}#{n}"
    end
  end

  defp apply_username_fixes(_keep, to_rename, _username_lower) do
    Enum.each(to_rename, fn user ->
      new_username = suggest_new_username(user.username, String.downcase(user.username))

      IO.puts("   Renaming user #{user.id}: #{user.username} -> #{new_username}")

      # Update the user's username
      user
      |> User.admin_changeset(%{username: new_username})
      |> Repo.update!()

      # Update their mailbox email if it exists
      case Repo.one(from m in Mailbox, where: m.user_id == ^user.id, limit: 1) do
        nil ->
          IO.puts("   No mailbox to update")

        mailbox ->
          mailbox
          |> Ecto.Changeset.change(email: "#{new_username}@elektrine.com")
          |> Repo.update!()

          IO.puts("   Updated mailbox email to #{new_username}@elektrine.com")
      end
    end)

    IO.puts("\n✅ Fixes applied successfully!")
  end

  defp confirm(prompt) do
    IO.write(prompt <> " (y/n) ")
    response = IO.gets("") |> String.trim() |> String.downcase()
    response in ["y", "yes"]
  end
end
