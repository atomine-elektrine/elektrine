defmodule Elektrine.ActivityPub.UserBlock do
  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_user_blocks" do
    field :blocked_uri, :string
    field :block_type, :string, default: "user"

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, [:user_id, :blocked_uri, :block_type])
    |> validate_required([:user_id, :blocked_uri])
    |> validate_inclusion(:block_type, ["user", "domain"])
    |> unique_constraint([:user_id, :blocked_uri])
  end
end
