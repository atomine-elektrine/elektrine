defmodule Elektrine.Repo.Migrations.AddVotersTrackingToPolls do
  use Ecto.Migration

  def change do
    alter table(:polls) do
      # Track unique voter count (separate from total_votes for multi-choice polls)
      add(:voters_count, :integer, default: 0)

      # Store voter actor URIs for federated polls (prevents double-voting)
      add(:voter_uris, {:array, :string}, default: [])
    end

    # Index for checking if a voter exists in the array
    create(index(:polls, [:voter_uris], using: :gin))
  end
end
