defmodule Elektrine.Repo.Migrations.AddOnboardingFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarding_completed, :boolean, default: false
      add :onboarding_completed_at, :utc_datetime
      add :onboarding_step, :integer, default: 1
    end

    create index(:users, [:onboarding_completed])

    # Mark all existing users as having completed onboarding
    # (Only new users created after this migration will go through onboarding)
    execute(
      "UPDATE users SET onboarding_completed = true, onboarding_completed_at = NOW() WHERE onboarding_completed IS NULL OR onboarding_completed = false",
      "UPDATE users SET onboarding_completed = false, onboarding_completed_at = NULL WHERE onboarding_completed = true"
    )
  end
end
