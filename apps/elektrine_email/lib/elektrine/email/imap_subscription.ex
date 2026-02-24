defmodule Elektrine.Email.ImapSubscription do
  @moduledoc """
  Persists IMAP folder subscriptions per user for LSUB/SUBSCRIBE/UNSUBSCRIBE.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "imap_subscriptions" do
    field :folder_name, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :folder_name])
    |> validate_required([:user_id, :folder_name])
    |> validate_length(:folder_name, min: 1, max: 255)
    |> unique_constraint([:user_id, :folder_name])
  end
end
