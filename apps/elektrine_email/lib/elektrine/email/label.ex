defmodule Elektrine.Email.Label do
  @moduledoc """
  Schema for email labels/tags.
  Allows users to tag emails with multiple labels for organization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_labels" do
    field :name, :string
    field :color, :string, default: "#3b82f6"

    belongs_to :user, Elektrine.Accounts.User
    many_to_many :messages, Elektrine.Email.Message, join_through: "email_message_labels"

    timestamps()
  end

  @valid_colors ~w(#ef4444 #f97316 #f59e0b #eab308 #84cc16 #22c55e #10b981 #14b8a6 #06b6d4 #0ea5e9 #3b82f6 #6366f1 #8b5cf6 #a855f7 #d946ef #ec4899 #f43f5e #6b7280)

  @doc """
  Creates a changeset for an email label.
  """
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 30)
    |> validate_inclusion(:color, @valid_colors, message: "is not a valid color")
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :name])
  end
end
