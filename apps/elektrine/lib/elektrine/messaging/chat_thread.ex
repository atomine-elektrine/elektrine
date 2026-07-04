defmodule Elektrine.Messaging.ChatThread do
  @moduledoc """
  Schema for chat threads.

  A thread is a focused side-conversation attached to a channel. It can be
  spawned from an existing message (`root_message_id`) or created standalone.
  Messages that belong to a thread carry `chat_messages.thread_id` and are
  excluded from the channel's main timeline; the root message (when present)
  stays in the main timeline.

  Remote threads projected from federation carry `federation_id` (the stable
  id assigned by the origin domain) plus `origin_domain`; local threads leave
  both nil.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_threads" do
    field :title, :string
    field :archived_at, :utc_datetime
    field :last_activity_at, :utc_datetime
    field :message_count, :integer, default: 0
    field :federation_id, :string
    field :origin_domain, :string

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :root_message, Elektrine.Messaging.ChatMessage
    belongs_to :creator, Elektrine.Accounts.User

    has_many :messages, Elektrine.Messaging.ChatMessage, foreign_key: :thread_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :conversation_id,
      :root_message_id,
      :title,
      :creator_id,
      :archived_at,
      :last_activity_at,
      :message_count,
      :federation_id,
      :origin_domain
    ])
    |> update_change(:title, &normalize_title/1)
    |> validate_required([:conversation_id, :title])
    |> validate_length(:title, min: 1, max: 100)
    |> validate_number(:message_count, greater_than_or_equal_to: 0)
    |> truncate_utc_datetimes([:archived_at, :last_activity_at])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:root_message_id)
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:root_message_id)
    |> unique_constraint([:federation_id, :origin_domain],
      name: :chat_threads_federation_id_origin_domain_index
    )
  end

  @doc """
  Returns true when the thread is archived.
  """
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.slice(0, 100)
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_title(title), do: title

  defp truncate_utc_datetimes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &Elektrine.Time.truncate/1)
    end)
  end
end
