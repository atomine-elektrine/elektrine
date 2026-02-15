defmodule Elektrine.Email.ForwardedMessage do
  @moduledoc """
  Schema for tracking forwarded email messages through alias chains.
  Records the forwarding path, hop count, and metadata for forwarded emails.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Email.Alias

  schema "forwarded_messages" do
    field :message_id, :string
    field :from_address, :string
    field :subject, :string
    field :original_recipient, :string
    field :final_recipient, :string
    field :forwarding_chain, :map
    field :total_hops, :integer

    belongs_to :alias, Alias

    timestamps()
  end

  def changeset(forwarded_message, attrs) do
    forwarded_message
    |> cast(attrs, [
      :message_id,
      :from_address,
      :subject,
      :original_recipient,
      :final_recipient,
      :forwarding_chain,
      :total_hops,
      :alias_id
    ])
    |> validate_required([:original_recipient, :final_recipient])
  end
end
