defmodule Elektrine.Jobs.StorageRecalculator do
  @moduledoc """
  Background job to recalculate storage usage for all users.
  Runs periodically to keep storage totals accurate.
  """

  require Logger
  alias Elektrine.Accounts.Storage
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @doc """
  Recalculates storage for all users.
  """
  def run do
    Logger.info("StorageRecalculator: Starting storage recalculation...")

    users = Repo.all(User)
    total = length(users)

    {success, errors} =
      Enum.reduce(users, {0, 0}, fn user, {success_count, error_count} ->
        try do
          Storage.update_user_storage(user.id)
          {success_count + 1, error_count}
        rescue
          e ->
            Logger.error("StorageRecalculator: Error for user #{user.id}: #{inspect(e)}")
            {success_count, error_count + 1}
        end
      end)

    Logger.info(
      "StorageRecalculator: Complete. #{success}/#{total} users updated, #{errors} errors"
    )

    :ok
  end
end
