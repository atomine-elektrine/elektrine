defmodule Elektrine.Messaging.Server do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messaging_servers" do
    field :name, :string
    field :description, :string
    field :icon_url, :string
    field :is_public, :boolean, default: false
    field :member_count, :integer, default: 0
    field :last_activity_at, :utc_datetime
    field :last_federated_at, :utc_datetime
    field :federation_id, :string
    field :origin_domain, :string
    field :is_federated_mirror, :boolean, default: false

    belongs_to :creator, Elektrine.Accounts.User
    has_many :members, Elektrine.Messaging.ServerMember, foreign_key: :server_id
    has_many :channels, Elektrine.Messaging.Conversation, foreign_key: :server_id

    timestamps()
  end

  @doc false
  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :description,
      :icon_url,
      :is_public,
      :member_count,
      :last_activity_at,
      :last_federated_at,
      :federation_id,
      :origin_domain,
      :is_federated_mirror,
      :creator_id
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_length(:description, max: 500)
    |> validate_name_security()
    |> maybe_validate_creator_id()
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:federation_id, name: :messaging_servers_federation_id_unique)
  end

  defp validate_name_security(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name when is_binary(name) ->
        cleaned_name =
          name
          |> String.replace(~r/<[^>]+>/, "")
          |> String.replace(~r/javascript:/i, "")
          |> String.trim()

        if cleaned_name == "" do
          add_error(changeset, :name, "cannot be empty")
        else
          put_change(changeset, :name, cleaned_name)
        end

      _ ->
        changeset
    end
  end

  defp maybe_validate_creator_id(changeset) do
    if get_field(changeset, :is_federated_mirror) do
      changeset
    else
      validate_required(changeset, [:creator_id])
    end
  end
end
