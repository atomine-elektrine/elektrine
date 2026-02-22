defmodule Elektrine.Social.List do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "lists" do
    field :name, :string
    field :description, :string
    field :visibility, :string, default: "public"

    belongs_to :user, Elektrine.Accounts.User
    has_many :list_members, Elektrine.Social.ListMember, on_delete: :delete_all

    timestamps()
  end

  @doc false
  def changeset(list, attrs) do
    list
    |> cast(attrs, [:user_id, :name, :description, :visibility])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:visibility, ["private", "public"])
    |> unique_constraint([:user_id, :name])
  end
end
