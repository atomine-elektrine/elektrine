defmodule Elektrine.Messaging.AutoModRule do
  @moduledoc """
  Schema for automated moderation rules that filter content.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "auto_mod_rules" do
    field :name, :string
    field :rule_type, :string
    field :pattern, :string
    field :action, :string
    field :enabled, :boolean, default: true

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :created_by, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :conversation_id,
      :name,
      :rule_type,
      :pattern,
      :action,
      :enabled,
      :created_by_id
    ])
    |> validate_required([:conversation_id, :name, :rule_type, :pattern, :action, :created_by_id])
    |> validate_inclusion(:rule_type, ["keyword", "link_domain", "spam_pattern"])
    |> validate_inclusion(:action, ["flag", "remove", "hold_for_review"])
    |> validate_length(:name, min: 3, max: 100)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:created_by_id)
  end
end
