defmodule Elektrine.Repo.Migrations.MigrateExistingKeysToSigningKeys do
  use Ecto.Migration

  @moduledoc false

  # This migration used to derive signing key ids from INSTANCE_URL at migration
  # time. The backfill is now an explicit operational step:
  # `mix activitypub.backfill_signing_keys`

  def up, do: :ok
  def down, do: :ok
end
