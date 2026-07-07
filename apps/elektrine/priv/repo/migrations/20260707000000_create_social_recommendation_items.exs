defmodule Elektrine.Repo.Migrations.CreateSocialRecommendationItems do
  use Ecto.Migration

  def change do
    create table(:social_recommendation_items) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:social_messages, on_delete: :delete_all), null: false
      add :filter, :string, null: false
      add :rank, :integer, null: false
      add :score, :integer, null: false, default: 0
      add :reason, :string
      add :generated_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:social_recommendation_items, [:user_id, :filter, :message_id],
             name: :social_recommendation_items_user_filter_message_unique
           )

    create unique_index(:social_recommendation_items, [:user_id, :filter, :rank],
             name: :social_recommendation_items_user_filter_rank_unique
           )

    create index(:social_recommendation_items, [:user_id, :filter, :expires_at, :rank],
             name: :social_recommendation_items_lookup_idx
           )

    create index(:social_recommendation_items, [:expires_at],
             name: :social_recommendation_items_expires_at_idx
           )
  end
end
