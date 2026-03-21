defmodule Elektrine.Repo.Migrations.AddRedemptionFieldsToRegistrationCheckouts do
  use Ecto.Migration

  def change do
    alter table(:registration_checkouts) do
      add :redeemed_at, :utc_datetime
      add :redeemed_by_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:registration_checkouts, [:redeemed_by_user_id])
    create index(:registration_checkouts, [:redeemed_at])
  end
end
