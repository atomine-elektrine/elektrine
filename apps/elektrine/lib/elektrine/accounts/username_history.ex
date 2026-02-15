defmodule Elektrine.Accounts.UsernameHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "username_history" do
    field :username, :string
    field :previous_username, :string
    field :changed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(username_history, attrs) do
    username_history
    |> cast(attrs, [:username, :previous_username, :changed_at, :user_id])
    |> validate_required([:username, :user_id, :changed_at])
    |> validate_length(:username, min: 1, max: 30)
    |> validate_length(:previous_username, max: 30)
    |> foreign_key_constraint(:user_id)
  end
end
