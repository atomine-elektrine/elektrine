defmodule Elektrine.Messaging.ChatConversation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_conversations" do
    field :name, :string
    field :description, :string
    field :type, :string
    field :avatar_url, :string
    field :is_public, :boolean, default: false
    field :member_count, :integer, default: 0
    field :last_message_at, :utc_datetime
    field :archived, :boolean, default: false
    field :hash, :string
    field :slow_mode_seconds, :integer, default: 0
    field :approval_mode_enabled, :boolean, default: false
    field :approval_threshold_posts, :integer, default: 3
    field :channel_topic, :string
    field :channel_position, :integer, default: 0
    field :federated_source, :string
    field :is_federated_mirror, :boolean, default: false

    belongs_to :remote_group_actor, Elektrine.ActivityPub.Actor
    belongs_to :creator, Elektrine.Accounts.User
    belongs_to :server, Elektrine.Messaging.Server
    has_many :channels, __MODULE__, foreign_key: :server_id
    has_many :members, Elektrine.Messaging.ChatConversationMember, foreign_key: :conversation_id
    has_many :users, through: [:members, :user]
    has_many :messages, Elektrine.Messaging.ChatMessage, foreign_key: :conversation_id

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :creator_id,
      :avatar_url,
      :is_public,
      :member_count,
      :last_message_at,
      :archived,
      :hash,
      :slow_mode_seconds,
      :approval_mode_enabled,
      :approval_threshold_posts,
      :channel_topic,
      :channel_position,
      :server_id,
      :federated_source,
      :is_federated_mirror,
      :remote_group_actor_id
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, ["dm", "group", "channel"])
    |> validate_length(:channel_topic, max: 300)
    |> validate_number(:channel_position, greater_than_or_equal_to: 0)
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:hash)
  end

  def dm_changeset(conversation, attrs) do
    changeset(conversation, Map.put(attrs, :type, "dm"))
  end

  def group_changeset(conversation, attrs) do
    changeset(conversation, Map.put(attrs, :type, "group"))
  end

  def channel_changeset(conversation, attrs) do
    changeset(conversation, Map.put(attrs, :type, "channel"))
  end
end
