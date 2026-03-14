defmodule Mix.Tasks.Users.ImportExisting do
  @moduledoc false
  use Mix.Task

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @shortdoc "Import pre-hashed users from an explicit string or file"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [users: :string, file: :string, dry_run: :boolean],
        aliases: [u: :users, f: :file, d: :dry_run]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    users_spec =
      opts[:users] ||
        read_users_file(opts[:file]) ||
        Mix.raise("Pass --users or --file with data in \"username,hash|username,hash\" format.")

    users_data = parse_users(users_spec)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if Enum.empty?(users_data) do
      Mix.shell().info("No users were parsed from the provided input.")
    else
      Enum.each(users_data, fn {username, password_hash} ->
        import_user(username, password_hash, dry_run?)
      end)
    end
  end

  defp import_user(username, password_hash, dry_run?) do
    existing_user = Repo.one(from(u in User, where: u.username == ^username))

    cond do
      existing_user ->
        Mix.shell().info("Skipping #{username}: user already exists.")

      dry_run? ->
        Mix.shell().info("Would import #{username}.")

      true ->
        %User{}
        |> User.import_changeset(%{username: username, password_hash: password_hash})
        |> Repo.insert!()

        Mix.shell().info("Imported #{username}.")
    end
  end

  defp read_users_file(nil), do: nil

  defp read_users_file(path) do
    path
    |> File.read!()
    |> String.trim()
  end

  defp parse_users(users_spec) do
    users_spec
    |> String.split("|", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_user_entry/1)
  end

  defp parse_user_entry(entry) do
    case String.split(entry, ",", parts: 2) do
      [username, password_hash] ->
        {String.trim(username), String.trim(password_hash)}

      _ ->
        Mix.raise("Invalid user entry: #{inspect(entry)}")
    end
  end
end
