defmodule Elektrine.Repo.Migrations.AddMastodonPollFields do
  use Ecto.Migration

  def change do
    alter table(:polls) do
      add :hide_totals, :boolean, default: false, null: false
      add :last_fetched_at, :utc_datetime
    end

    create index(:polls, [:last_fetched_at])
  end
end
