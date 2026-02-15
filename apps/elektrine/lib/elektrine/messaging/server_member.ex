defmodule Elektrine.Messaging.ServerMember do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_server_members" do
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime
    field :notifications_enabled, :boolean, default: true

    belongs_to :server, Elektrine.Messaging.Server
    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :server_id,
      :user_id,
      :role,
      :joined_at,
      :left_at,
      :notifications_enabled
    ])
    |> validate_required([:server_id, :user_id])
    |> validate_inclusion(:role, ["owner", "admin", "moderator", "member"])
    |> foreign_key_constraint(:server_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:server_id, :user_id])
    |> maybe_set_joined_at()
  end

  @doc """
  Creates a changeset for adding a member to a server.
  """
  def add_member_changeset(server_id, user_id, role \\ "member") do
    %__MODULE__{}
    |> changeset(%{
      server_id: server_id,
      user_id: user_id,
      role: role,
      joined_at: DateTime.utc_now()
    })
  end

  defp maybe_set_joined_at(changeset) do
    case get_field(changeset, :joined_at) do
      nil -> put_change(changeset, :joined_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
