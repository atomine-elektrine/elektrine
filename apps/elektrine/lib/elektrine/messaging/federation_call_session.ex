defmodule Elektrine.Messaging.FederationCallSession do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @valid_call_types ~w(audio video)
  @valid_directions ~w(inbound outbound)
  @valid_statuses ~w(initiated ringing active ended rejected missed failed)

  schema "messaging_federation_call_sessions" do
    field :federated_call_id, :string
    field :origin_domain, :string
    field :remote_domain, :string
    field :remote_handle, :string
    field :remote_actor, :map, default: %{}
    field :call_type, :string
    field :direction, :string
    field :status, :string
    field :metadata, :map, default: %{}
    field :started_at_remote, :utc_datetime
    field :ended_at_remote, :utc_datetime

    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :local_user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :conversation_id,
      :local_user_id,
      :federated_call_id,
      :origin_domain,
      :remote_domain,
      :remote_handle,
      :remote_actor,
      :call_type,
      :direction,
      :status,
      :metadata,
      :started_at_remote,
      :ended_at_remote
    ])
    |> validate_required([
      :conversation_id,
      :local_user_id,
      :federated_call_id,
      :origin_domain,
      :remote_domain,
      :remote_handle,
      :call_type,
      :direction,
      :status
    ])
    |> validate_length(:federated_call_id, max: 500)
    |> validate_length(:origin_domain, max: 255)
    |> validate_length(:remote_domain, max: 255)
    |> validate_length(:remote_handle, max: 255)
    |> validate_inclusion(:call_type, @valid_call_types)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:local_user_id)
    |> unique_constraint([:local_user_id, :federated_call_id],
      name: :messaging_federation_call_sessions_user_call_unique
    )
  end
end
