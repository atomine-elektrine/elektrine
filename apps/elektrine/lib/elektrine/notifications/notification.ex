defmodule Elektrine.Notifications.Notification do
  @moduledoc """
  Schema for user notifications across the platform.
  Supports various notification types including messages, mentions, follows, and system alerts with priority levels and read/seen tracking.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "notifications" do
    field :type, :string
    field :title, :string
    field :body, :string
    field :url, :string
    field :icon, :string
    field :priority, :string, default: "normal"

    field :read_at, :utc_datetime
    field :seen_at, :utc_datetime
    field :dismissed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :actor, Elektrine.Accounts.User

    field :source_type, :string
    field :source_id, :integer

    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :type,
      :title,
      :body,
      :url,
      :icon,
      :priority,
      :user_id,
      :actor_id,
      :source_type,
      :source_id,
      :metadata,
      :read_at,
      :seen_at,
      :dismissed_at
    ])
    |> validate_required([:type, :title, :user_id])
    |> validate_inclusion(:type, [
      "new_message",
      "mention",
      "reply",
      "follow",
      "like",
      "comment",
      "discussion_reply",
      "email_received",
      "system"
    ])
    |> validate_inclusion(:priority, ["low", "normal", "high", "urgent"])
  end
end
