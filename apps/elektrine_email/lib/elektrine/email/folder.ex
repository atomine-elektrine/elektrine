defmodule Elektrine.Email.Folder do
  @moduledoc """
  Schema for custom email folders.
  Allows users to organize emails into custom folders.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_folders" do
    field :name, :string
    field :color, :string
    field :icon, :string

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :messages, Elektrine.Email.Message

    timestamps()
  end

  @valid_colors ~w(#ef4444 #f97316 #f59e0b #eab308 #84cc16 #22c55e #10b981 #14b8a6 #06b6d4 #0ea5e9 #3b82f6 #6366f1 #8b5cf6 #a855f7 #d946ef #ec4899 #f43f5e)
  @valid_icons ~w(folder inbox archive star flag bookmark tag briefcase file document mail)

  @doc """
  Creates a changeset for a custom folder.
  """
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:name, :color, :icon, :parent_id, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 50)
    |> validate_inclusion(:color, @valid_colors, message: "is not a valid color")
    |> validate_inclusion(:icon, @valid_icons, message: "is not a valid icon")
    |> validate_not_reserved()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint([:user_id, :name])
  end

  @reserved_names ~w(inbox sent drafts trash spam archive stack feed ledger boomerang)

  defp validate_not_reserved(changeset) do
    name = get_field(changeset, :name)

    if name && String.downcase(name) in @reserved_names do
      add_error(changeset, :name, "is a reserved folder name")
    else
      changeset
    end
  end
end
