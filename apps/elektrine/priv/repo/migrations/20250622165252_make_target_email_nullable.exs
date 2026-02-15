defmodule Elektrine.Repo.Migrations.MakeTargetEmailNullable do
  use Ecto.Migration

  def change do
    alter table(:email_aliases) do
      modify :target_email, :string, null: true
    end
  end
end
