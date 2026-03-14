defmodule Elektrine.Repo.Migrations.ImportExistingUsers do
  use Ecto.Migration

  @moduledoc false

  # This migration used to import host-specific users from IMPORT_USERS.
  # That made schema history depend on ephemeral deploy-time input, so the
  # import now lives in `mix users.import_existing`.

  def up, do: :ok
  def down, do: :ok
end
