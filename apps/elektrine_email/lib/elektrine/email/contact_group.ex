defmodule Elektrine.Email.ContactGroup do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "contact_groups" do
    field :name, :string
    field :color, :string, default: "#3b82f6"

    belongs_to :user, Elektrine.Accounts.User
    has_many :contacts, Elektrine.Email.Contact, foreign_key: :group_id

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:user_id, :name, :color])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, max: 100)
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/)
  end
end
