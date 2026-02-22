defmodule Elektrine.Social.Hashtag do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "hashtags" do
    field :name, :string
    field :normalized_name, :string
    field :use_count, :integer, default: 0
    field :last_used_at, :utc_datetime

    many_to_many :messages, Elektrine.Messaging.Message,
      join_through: "post_hashtags",
      on_replace: :delete

    timestamps()
  end

  @doc false
  def changeset(hashtag, attrs) do
    hashtag
    |> cast(attrs, [:name, :normalized_name, :use_count, :last_used_at])
    |> validate_required([:name, :normalized_name])
    |> validate_length(:name, min: 1, max: 50)
    |> validate_format(:name, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> put_normalized_name()
    |> unique_constraint(:normalized_name)
  end

  defp put_normalized_name(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :normalized_name, String.downcase(name))
    end
  end
end
