defmodule Mix.Tasks.Admin.Make do
  @moduledoc """
  Make a user an admin.

  ## Examples

      mix admin.make username

  """
  use Mix.Task

  alias Elektrine.Accounts

  @shortdoc "Make a user an admin"

  def run([username]) when is_binary(username) do
    Mix.Task.run("app.start")

    case Accounts.get_user_by_username(username) do
      nil ->
        Mix.shell().error("User '#{username}' not found.")

      %{is_admin: true} = user ->
        Mix.shell().info("User '#{user.username}' is already an admin.")

      user ->
        case Accounts.update_user_admin_status(user, true) do
          {:ok, _updated_user} ->
            Mix.shell().info("Successfully made '#{user.username}' an admin.")

          {:error, changeset} ->
            Mix.shell().error("Failed to make user admin: #{inspect(changeset.errors)}")
        end
    end
  end

  def run([]) do
    Mix.shell().error("Usage: mix admin.make <username>")
  end

  def run(_) do
    Mix.shell().error("Usage: mix admin.make <username>")
  end
end
