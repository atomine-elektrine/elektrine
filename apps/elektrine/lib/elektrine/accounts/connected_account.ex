defmodule Elektrine.Accounts.ConnectedAccount do
  @moduledoc """
  A reusable external account connection owned by a user.

  These records are created by provider OAuth/OIDC flows and can be consumed by
  modules such as Atomine proofs, static-site deploy integrations, importers, or
  webhook setup without each module owning a separate provider identity table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(github gitlab google discord x mastodon bluesky)

  schema "connected_accounts" do
    belongs_to :user, Elektrine.Accounts.User
    field :provider, :string
    field :provider_account_id, :string
    field :username, :string
    field :display_name, :string
    field :email, :string
    field :profile_url, :string
    field :avatar_url, :string
    field :scopes, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :last_verified_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers

  def changeset(connected_account, attrs) do
    connected_account
    |> cast(attrs, [
      :user_id,
      :provider,
      :provider_account_id,
      :username,
      :display_name,
      :email,
      :profile_url,
      :avatar_url,
      :scopes,
      :metadata,
      :last_verified_at
    ])
    |> normalize_string(:provider)
    |> normalize_string(:provider_account_id)
    |> normalize_optional_string(:username)
    |> normalize_optional_string(:display_name)
    |> normalize_optional_string(:email)
    |> validate_required([:user_id, :provider, :provider_account_id])
    |> validate_inclusion(:provider, @providers)
    |> validate_length(:provider_account_id, min: 1, max: 500)
    |> validate_length(:username, max: 500)
    |> validate_length(:display_name, max: 500)
    |> validate_length(:email, max: 500)
    |> validate_length(:profile_url, max: 2_000)
    |> validate_length(:avatar_url, max: 2_000)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :provider_account_id])
    |> unique_constraint([:user_id, :provider, :provider_account_id],
      name: :connected_accounts_user_provider_account_unique
    )
  end

  defp normalize_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end

  defp normalize_optional_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value -> value
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
