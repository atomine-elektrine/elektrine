defmodule Mix.Tasks.Activitypub.BackfillSigningKeys do
  @moduledoc false
  use Mix.Task

  import Ecto.Query

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.SigningKey
  alias Elektrine.Repo

  @shortdoc "Backfill ActivityPub signing_keys rows from existing local and remote keys"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, local_only: :boolean, remote_only: :boolean],
        aliases: [d: :dry_run]
      )

    if invalid != [] do
      Mix.raise("Invalid arguments: #{inspect(invalid)}")
    end

    local_only? = Keyword.get(opts, :local_only, false)
    remote_only? = Keyword.get(opts, :remote_only, false)

    if local_only? and remote_only? do
      Mix.raise("Use at most one of --local-only or --remote-only.")
    end

    dry_run? = Keyword.get(opts, :dry_run, false)

    local_users =
      if remote_only? do
        []
      else
        Repo.all(
          from(u in User,
            where: u.activitypub_enabled == true,
            where: not is_nil(u.activitypub_public_key) and u.activitypub_public_key != "",
            where: not is_nil(u.activitypub_private_key) and u.activitypub_private_key != ""
          )
        )
      end

    remote_actors =
      if local_only? do
        []
      else
        Repo.all(
          from(a in Actor,
            where: not is_nil(a.uri) and a.uri != "",
            where: not is_nil(a.public_key) and a.public_key != ""
          )
        )
      end

    Mix.shell().info("ActivityPub signing key backfill")
    Mix.shell().info("  Instance URL: #{Elektrine.ActivityPub.instance_url()}")
    Mix.shell().info("  Local users: #{length(local_users)}")
    Mix.shell().info("  Remote actors: #{length(remote_actors)}")
    Mix.shell().info("  Dry run: #{dry_run?}")

    unless dry_run? do
      Enum.each(local_users, &upsert_local_key/1)
      Enum.each(remote_actors, &upsert_remote_key/1)
    end
  end

  defp upsert_local_key(user) do
    case SigningKey.upsert_local_key(
           user,
           user.activitypub_public_key,
           user.activitypub_private_key
         ) do
      {:ok, _key} ->
        Mix.shell().info("Upserted local signing key for #{user.username}.")

      {:error, reason} ->
        Mix.raise("Failed to upsert local signing key for #{user.username}: #{inspect(reason)}")
    end
  end

  defp upsert_remote_key(actor) do
    attrs = %{
      key_id: actor.uri <> "#main-key",
      remote_actor_id: actor.id,
      public_key: actor.public_key
    }

    case %SigningKey{}
         |> SigningKey.remote_changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:public_key, :updated_at]},
           conflict_target: :key_id,
           returning: true
         ) do
      {:ok, _key} ->
        Mix.shell().info("Upserted remote signing key for #{actor.uri}.")

      {:error, reason} ->
        Mix.raise("Failed to upsert remote signing key for #{actor.uri}: #{inspect(reason)}")
    end
  end
end
