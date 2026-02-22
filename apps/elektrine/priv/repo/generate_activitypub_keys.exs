# Script to generate ActivityPub RSA keys for existing users
# Run with: mix run priv/repo/generate_activitypub_keys.exs

require Logger
import Ecto.Query

alias Elektrine.Accounts.User
alias Elektrine.ActivityPub.HTTPSignature
alias Elektrine.Repo

# Find all users without ActivityPub keys
users_without_keys =
  from(u in User,
    where: is_nil(u.activitypub_public_key) or is_nil(u.activitypub_private_key)
  )
  |> Repo.all()

Logger.info("Found #{length(users_without_keys)} users without ActivityPub keys")

Enum.each(users_without_keys, fn user ->
  Logger.info("Generating keys for user: #{user.username}")

  {public_key, private_key} = HTTPSignature.generate_key_pair()

  user
  |> Ecto.Changeset.change(%{
    activitypub_public_key: public_key,
    activitypub_private_key: private_key
  })
  |> Repo.update!()

  Logger.info("✓ Generated keys for #{user.username}")
end)

Logger.info("Done! Generated keys for #{length(users_without_keys)} users")
