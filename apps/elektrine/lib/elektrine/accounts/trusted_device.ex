defmodule Elektrine.Accounts.TrustedDevice do
  @moduledoc """
  Schema for trusted devices that can skip 2FA verification.
  Devices are trusted for 30 days by default.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "trusted_devices" do
    field :device_token, :string
    field :device_name, :string
    field :user_agent, :string
    field :ip_address, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(trusted_device, attrs) do
    trusted_device
    |> cast(attrs, [
      :user_id,
      :device_token,
      :device_name,
      :user_agent,
      :ip_address,
      :last_used_at,
      :expires_at
    ])
    |> validate_required([:user_id, :device_token])
    |> unique_constraint(:device_token)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Generates a new trusted device with a secure random token.
  Devices are trusted for 30 days by default.
  """
  def new_trusted_device(user_id, attrs \\ %{}) do
    device_token = generate_device_token()
    expires_at = DateTime.utc_now() |> DateTime.add(30, :day)

    default_attrs = %{
      user_id: user_id,
      device_token: device_token,
      last_used_at: DateTime.utc_now(),
      expires_at: expires_at
    }

    attrs = Map.merge(default_attrs, attrs)

    %__MODULE__{}
    |> changeset(attrs)
  end

  @doc """
  Generates a secure random device token.
  """
  def generate_device_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Checks if a trusted device is still valid (not expired).
  """
  def valid?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end
end
