defmodule Elektrine.Repo.Migrations.ImportExistingUsers do
  use Ecto.Migration
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Accounts.User

  def up do
    # Read user data from environment variable
    # Format: "username1,hash1|username2,hash2|..."
    users_env = System.get_env("IMPORT_USERS")

    users_data =
      if users_env do
        parse_users_from_env(users_env)
      else
        IO.puts("No IMPORT_USERS environment variable found, skipping user import")
        []
      end

    _now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(users_data, fn {username, password_hash} ->
      # Check if user already exists
      existing_user = Repo.one(from(u in User, where: u.username == ^username))

      if is_nil(existing_user) do
        %User{}
        |> User.import_changeset(%{
          username: username,
          password_hash: password_hash
        })
        |> Repo.insert!()

        IO.puts("Imported user: #{username}")
      else
        IO.puts("User #{username} already exists, skipping...")
      end
    end)
  end

  def down do
    # Read user data from environment variable to get usernames for removal
    users_env = System.get_env("IMPORT_USERS")

    if users_env do
      users_data = parse_users_from_env(users_env)
      usernames = Enum.map(users_data, fn {username, _hash} -> username end)

      Enum.each(usernames, fn username ->
        case Repo.get_by(User, username: username) do
          nil ->
            IO.puts("User #{username} not found, skipping...")

          user ->
            Repo.delete!(user)
            IO.puts("Removed user: #{username}")
        end
      end)
    else
      IO.puts("No IMPORT_USERS environment variable found, no users to remove")
    end
  end

  # Helper function to parse the environment variable
  # Format: "username1,hash1|username2,hash2|..."
  defp parse_users_from_env(users_env) do
    users_env
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn user_string ->
      case String.split(user_string, ",", parts: 2) do
        [username, hash] ->
          {String.trim(username), String.trim(hash)}

        _ ->
          IO.puts("Invalid user format: #{user_string}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
