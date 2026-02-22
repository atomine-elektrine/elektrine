defmodule Elektrine.Messaging.ConversationMember do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_members" do
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime
    field :last_read_at, :utc_datetime
    field :notifications_enabled, :boolean, default: true
    field :pinned, :boolean, default: false

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :last_read_message, Elektrine.Messaging.Message

    timestamps()
  end

  @doc false
  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :conversation_id,
      :user_id,
      :role,
      :joined_at,
      :left_at,
      :last_read_at,
      :last_read_message_id,
      :notifications_enabled,
      :pinned
    ])
    |> validate_required([:conversation_id, :user_id])
    |> validate_inclusion(:role, ["owner", "admin", "moderator", "member", "readonly"])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:last_read_message_id)
    |> unique_constraint([:conversation_id, :user_id])
    |> maybe_set_joined_at()
  end

  defp maybe_set_joined_at(changeset) do
    case get_field(changeset, :joined_at) do
      nil -> put_change(changeset, :joined_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Creates a changeset for adding a member to a conversation.
  """
  def add_member_changeset(conversation_id, user_id, role \\ "member") do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      user_id: user_id,
      role: role,
      joined_at: DateTime.utc_now()
    })
  end

  @doc """
  Creates a changeset for removing a member from a conversation.
  """
  def remove_member_changeset(member) do
    member
    |> changeset(%{left_at: DateTime.utc_now()})
  end

  @doc """
  Creates a changeset for updating the last read timestamp.
  """
  def mark_as_read_changeset(member) do
    member
    |> changeset(%{last_read_at: DateTime.utc_now()})
  end

  @doc """
  Creates a changeset for updating the last read message.
  """
  def update_last_read_message_changeset(member, message_id) do
    member
    |> changeset(%{
      last_read_at: DateTime.utc_now(),
      last_read_message_id: message_id
    })
  end

  @doc """
  Checks if the member is currently active (not left).
  """
  def active?(%__MODULE__{left_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  Checks if the member can send messages.
  """
  def can_send_messages?(%__MODULE__{role: "readonly"}), do: false
  def can_send_messages?(%__MODULE__{left_at: nil}), do: true
  def can_send_messages?(%__MODULE__{}), do: false

  @doc """
  Checks if the member is an admin.
  """
  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(%__MODULE__{}), do: false
end
