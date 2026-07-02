defmodule Elektrine.Social.ThreadMute do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "social_thread_mutes" do
    field :thread_key, :string

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Social.Message

    timestamps()
  end

  def changeset(thread_mute, attrs) do
    thread_mute
    |> cast(attrs, [:user_id, :thread_key, :message_id])
    |> validate_required([:user_id, :thread_key])
    |> unique_constraint([:user_id, :thread_key], name: :social_thread_mutes_user_thread_unique)
  end
end
