defmodule Elektrine.Repo.Migrations.AllowNullToInEmailMessages do
  use Ecto.Migration

  def change do
    alter table(:email_messages) do
      modify :to, :string, null: true, from: {:string, null: false}
    end
  end
end
