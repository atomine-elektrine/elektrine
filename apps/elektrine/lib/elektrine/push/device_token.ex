defmodule Elektrine.Push.DeviceToken do
  @moduledoc """
  Schema for device tokens used for push notifications.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "device_tokens" do
    field :token, :string
    field :platform, :string
    field :app_version, :string
    field :device_name, :string
    field :device_model, :string
    field :os_version, :string
    field :bundle_id, :string
    field :enabled, :boolean, default: true
    field :last_used_at, :utc_datetime
    field :failed_count, :integer, default: 0
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(device_token, attrs) do
    device_token
    |> cast(attrs, [
      :token,
      :platform,
      :app_version,
      :device_name,
      :device_model,
      :os_version,
      :bundle_id,
      :user_id,
      :enabled,
      :last_used_at,
      :failed_count,
      :last_error
    ])
    |> validate_required([:token, :platform, :user_id])
    |> validate_inclusion(:platform, ["ios", "android"])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end
end
