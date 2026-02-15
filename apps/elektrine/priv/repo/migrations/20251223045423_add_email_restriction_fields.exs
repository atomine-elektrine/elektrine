defmodule Elektrine.Repo.Migrations.AddEmailRestrictionFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_sending_restricted, :boolean, default: false
      add :email_rate_limit_violations, :integer, default: 0
      add :email_restriction_reason, :string
      add :email_restricted_at, :utc_datetime
      add :recovery_email_verified, :boolean, default: false
      add :recovery_email_verification_token, :string
      add :recovery_email_verification_sent_at, :utc_datetime
    end

    # Index for finding restricted users
    create index(:users, [:email_sending_restricted], where: "email_sending_restricted = true")
  end
end
