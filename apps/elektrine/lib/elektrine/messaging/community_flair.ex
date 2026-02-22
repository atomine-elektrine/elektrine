defmodule Elektrine.Messaging.CommunityFlair do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "community_flairs" do
    field :name, :string
    field :text_color, :string, default: "#FFFFFF"
    field :background_color, :string, default: "#4B5563"
    field :position, :integer, default: 0
    field :is_mod_only, :boolean, default: false
    field :is_enabled, :boolean, default: true

    belongs_to :community, Elektrine.Messaging.Conversation
    has_many :messages, Elektrine.Messaging.Message, foreign_key: :flair_id

    timestamps()
  end

  @doc false
  def changeset(flair, attrs) do
    flair
    |> cast(attrs, [
      :name,
      :text_color,
      :background_color,
      :community_id,
      :position,
      :is_mod_only,
      :is_enabled
    ])
    |> validate_required([:name, :community_id])
    |> validate_length(:name, min: 1, max: 30)
    |> validate_format(:text_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a valid hex color")
    |> validate_format(:background_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color"
    )
    |> unique_constraint(:name,
      name: :community_flairs_community_id_name_index,
      message: "Flair name already exists in this community"
    )
    |> foreign_key_constraint(:community_id)
  end
end
