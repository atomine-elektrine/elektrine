defmodule Elektrine.Email.Unsubscribe do
  @moduledoc """
  Schema for email unsubscribe tracking (RFC 8058).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_unsubscribes" do
    field :email, :string
    field :list_id, :string
    field :token, :string
    field :unsubscribed_at, :utc_datetime
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(unsubscribe, attrs) do
    unsubscribe
    |> cast(attrs, [
      :email,
      :user_id,
      :list_id,
      :token,
      :unsubscribed_at,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:email, :token, :unsubscribed_at])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint([:email, :list_id])
  end
end
