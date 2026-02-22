defmodule Mix.Tasks.Email.RecalculateStorage do
  @moduledoc """
  Recalculates storage usage for all users (centralized storage tracking).

  This task will:
  - Go through all users in the system
  - Calculate the actual storage used across emails, chat, and profile
  - Update the storage_used_bytes field for each user

  Usage:
    mix email.recalculate_storage
  """

  use Mix.Task

  alias Elektrine.Accounts.Storage
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  require Logger

  @shortdoc "Recalculates storage usage for all users"

  def run(_args) do
    Mix.Task.run("app.start")

    Logger.info("Starting centralized storage recalculation for all users...")

    # Get all users
    users = Repo.all(User)

    total_users = length(users)
    Logger.info("Found #{total_users} users to process")

    # Process each user
    {updated_count, error_count} =
      users
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {user, index}, {updated_acc, error_acc} ->
        Logger.info("Processing user #{index}/#{total_users}: #{user.username}")

        try do
          # Calculate and update storage
          {:ok, total_bytes} = Storage.update_user_storage(user.id)
          Logger.info("  ✓ Updated storage: #{Storage.format_bytes(total_bytes)}")
          {updated_acc + 1, error_acc}
        rescue
          e ->
            Logger.error("  ✗ Error processing user: #{inspect(e)}")
            {updated_acc, error_acc + 1}
        end
      end)

    Logger.info("Storage recalculation completed!")
    Logger.info("Successfully updated: #{updated_count} users")
    Logger.info("Errors: #{error_count} users")

    if error_count > 0 do
      Logger.warning("Some users had errors during recalculation. Please check the logs above.")
    else
      Logger.info("All users processed successfully!")
    end
  end
end
