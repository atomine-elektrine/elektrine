defmodule Elektrine.Messaging.UserHiddenMessage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_hidden_messages" do
    field :hidden_at, :naive_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message

    timestamps()
  end

  @doc false
  def changeset(hidden_message, attrs) do
    hidden_message
    |> cast(attrs, [:user_id, :message_id, :hidden_at])
    |> validate_required([:user_id, :message_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:user_id, :message_id])
  end

  @doc """
  Creates a changeset for hiding a message for a user.
  """
  def hide_message_changeset(user_id, message_id) do
    %__MODULE__{}
    |> changeset(%{
      user_id: user_id,
      message_id: message_id,
      hidden_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    })
  end
end
