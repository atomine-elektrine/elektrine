defmodule Elektrine.Messaging.UserTimeout do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_timeouts" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :created_by, Elektrine.Accounts.User
    field :timeout_until, :utc_datetime
    field :reason, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_timeout, attrs) do
    user_timeout
    |> cast(attrs, [:user_id, :conversation_id, :timeout_until, :reason, :created_by_id])
    |> validate_required([:user_id, :timeout_until, :created_by_id])
    |> validate_future_timeout()
    |> unique_constraint([:user_id, :conversation_id],
      name: :user_timeouts_user_conversation_unique
    )
  end

  defp validate_future_timeout(changeset) do
    case get_field(changeset, :timeout_until) do
      nil ->
        changeset

      timeout_until ->
        if DateTime.compare(timeout_until, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :timeout_until, "must be in the future")
        end
    end
  end

  def active?(user_timeout) do
    DateTime.compare(user_timeout.timeout_until, DateTime.utc_now()) == :gt
  end
end
