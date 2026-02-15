defmodule Elektrine.Repo.Migrations.CreateCustomEmojis do
  use Ecto.Migration

  def change do
    create table(:custom_emojis) do
      add :shortcode, :string, null: false
      add :image_url, :string, null: false
      add :instance_domain, :string
      add :category, :string
      add :visible_in_picker, :boolean, default: true
      add :disabled, :boolean, default: false

      timestamps()
    end

    # Shortcode must be unique per instance (local emojis have null domain)
    create unique_index(:custom_emojis, [:shortcode, :instance_domain])
    create index(:custom_emojis, [:instance_domain])
    create index(:custom_emojis, [:visible_in_picker])
  end
end
