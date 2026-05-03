defmodule Elektrine.Messaging.ChatConversationKeyRecipient do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_conversation_key_recipients" do
    field :device_id, :string
    field :wrapped_key, :map

    belongs_to :conversation_key, Elektrine.Messaging.ChatConversationEncryptionKey
    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:conversation_key_id, :user_id, :device_id, :wrapped_key])
    |> validate_required([:conversation_key_id, :user_id, :device_id, :wrapped_key])
    |> validate_length(:device_id, min: 8, max: 128)
    |> validate_wrapped_key()
    |> foreign_key_constraint(:conversation_key_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:conversation_key_id, :user_id, :device_id])
  end

  defp validate_wrapped_key(changeset) do
    case get_field(changeset, :wrapped_key) do
      %{} = wrapped_key ->
        version = payload_value(wrapped_key, "version", :version)
        key_algorithm = payload_value(wrapped_key, "key_algorithm", :key_algorithm)
        encrypted_key = payload_value(wrapped_key, "encrypted_key", :encrypted_key)

        if version in [1, "1"] and key_algorithm == "RSA-OAEP-SHA256" and
             valid_base64?(encrypted_key) do
          changeset
        else
          add_error(changeset, :wrapped_key, "must be a valid wrapped chat key")
        end

      _ ->
        add_error(changeset, :wrapped_key, "must be a valid wrapped chat key")
    end
  end

  defp payload_value(payload, string_key, atom_key) do
    Map.get(payload, string_key) || Map.get(payload, atom_key)
  end

  defp valid_base64?(value) when is_binary(value) do
    match?({:ok, decoded} when byte_size(decoded) > 16, Base.decode64(value))
  end

  defp valid_base64?(_), do: false
end
