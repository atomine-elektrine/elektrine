defmodule Elektrine.Social.RecommendationItem do
  @moduledoc """
  Persisted ranked recommendation entry for a user/feed filter.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @filters ~w(all timeline gallery discussions)

  schema "social_recommendation_items" do
    field :filter, :string
    field :rank, :integer
    field :score, :integer, default: 0
    field :reason, :string
    field :generated_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Social.Message

    timestamps(type: :utc_datetime)
  end

  def filters, do: @filters

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :user_id,
      :message_id,
      :filter,
      :rank,
      :score,
      :reason,
      :generated_at,
      :expires_at
    ])
    |> validate_required([:user_id, :message_id, :filter, :rank, :generated_at, :expires_at])
    |> validate_inclusion(:filter, @filters)
    |> validate_number(:rank, greater_than: 0)
    |> validate_number(:score, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:user_id, :filter, :message_id],
      name: :social_recommendation_items_user_filter_message_unique
    )
    |> unique_constraint([:user_id, :filter, :rank],
      name: :social_recommendation_items_user_filter_rank_unique
    )
  end
end
