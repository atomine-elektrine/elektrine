defmodule Elektrine.Messaging.MemberSchemaBase do
  @moduledoc """
  Shared schema/changeset/predicate definitions for conversation member schemas.

  Used by both `Elektrine.Messaging.ChatConversationMember` and
  `Elektrine.Social.ConversationMember`, which were previously near-identical.

  ## Usage

      use Elektrine.Messaging.MemberSchemaBase,
        table: "chat_conversation_members",
        conversation: Elektrine.Messaging.ChatConversation,
        message: Elektrine.Messaging.ChatMessage

  Options:

    * `:table` (required) - the database table name.
    * `:conversation` (required) - the module for the `belongs_to :conversation`
      association.
    * `:message` (required) - the module for the `belongs_to :last_read_message`
      association.

  All injected functions reference `__MODULE__`, so `%__MODULE__{}` patterns
  resolve to the using module, preserving struct-specific dispatch.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    conversation = Keyword.fetch!(opts, :conversation)
    message = Keyword.fetch!(opts, :message)

    quote do
      use Ecto.Schema
      import Ecto.Changeset

      schema unquote(table) do
        field :role, :string, default: "member"
        field :joined_at, :utc_datetime
        field :left_at, :utc_datetime
        field :last_read_at, :utc_datetime
        field :notifications_enabled, :boolean, default: true
        field :pinned, :boolean, default: false

        belongs_to :conversation, unquote(conversation)
        belongs_to :user, Elektrine.Accounts.User
        belongs_to :last_read_message, unquote(message)

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
        |> truncate_utc_datetimes([:joined_at, :left_at, :last_read_at])
        |> validate_required([:conversation_id, :user_id])
        |> validate_inclusion(:role, ["owner", "admin", "moderator", "member", "readonly"])
        |> foreign_key_constraint(:conversation_id)
        |> foreign_key_constraint(:user_id)
        |> foreign_key_constraint(:last_read_message_id)
        |> unique_constraint([:conversation_id, :user_id])
        |> maybe_set_joined_at()
      end

      def add_member_changeset(conversation_id, user_id, role \\ "member") do
        %__MODULE__{}
        |> changeset(%{
          conversation_id: conversation_id,
          user_id: user_id,
          role: role,
          joined_at: Elektrine.Time.utc_now()
        })
      end

      def remove_member_changeset(member) do
        member
        |> changeset(%{left_at: Elektrine.Time.utc_now()})
      end

      def mark_as_read_changeset(member) do
        member
        |> changeset(%{last_read_at: Elektrine.Time.utc_now()})
      end

      def update_last_read_message_changeset(member, message_id) do
        member
        |> changeset(%{
          last_read_at: Elektrine.Time.utc_now(),
          last_read_message_id: message_id
        })
      end

      def active?(%__MODULE__{left_at: nil}), do: true
      def active?(%__MODULE__{}), do: false

      def can_send_messages?(%__MODULE__{role: "readonly"}), do: false
      def can_send_messages?(%__MODULE__{left_at: nil}), do: true
      def can_send_messages?(%__MODULE__{}), do: false

      def admin?(%__MODULE__{role: "admin"}), do: true
      def admin?(%__MODULE__{}), do: false

      defp maybe_set_joined_at(changeset) do
        case get_field(changeset, :joined_at) do
          nil -> put_change(changeset, :joined_at, Elektrine.Time.utc_now())
          _ -> changeset
        end
      end

      defp truncate_utc_datetimes(changeset, fields) do
        Enum.reduce(fields, changeset, fn field, changeset ->
          update_change(changeset, field, &Elektrine.Time.truncate/1)
        end)
      end

      defoverridable can_send_messages?: 1, admin?: 1
    end
  end
end
