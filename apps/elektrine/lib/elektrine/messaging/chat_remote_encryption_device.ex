defmodule Elektrine.Messaging.ChatRemoteEncryptionDevice do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_remote_encryption_devices" do
    field :origin_domain, :string
    field :remote_handle, :string
    field :device_id, :string
    field :public_key, :map
    field :key_algorithm, :string, default: "RSA-OAEP-SHA256"
    field :label, :string
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :origin_domain,
      :remote_handle,
      :device_id,
      :public_key,
      :key_algorithm,
      :label,
      :last_seen_at,
      :revoked_at
    ])
    |> validate_required([
      :origin_domain,
      :remote_handle,
      :device_id,
      :public_key,
      :key_algorithm
    ])
    |> validate_length(:origin_domain, min: 3, max: 253)
    |> validate_length(:remote_handle, min: 3, max: 255)
    |> validate_length(:device_id, min: 8, max: 128)
    |> validate_length(:label, max: 120)
    |> validate_inclusion(:key_algorithm, ["RSA-OAEP-SHA256"])
    |> validate_public_key()
    |> unique_constraint([:origin_domain, :remote_handle, :device_id])
  end

  defp validate_public_key(changeset) do
    case get_field(changeset, :public_key) do
      %{} = public_key ->
        version = payload_value(public_key, "version", :version)
        algorithm = payload_value(public_key, "algorithm", :algorithm)
        key = payload_value(public_key, "key", :key)

        if version in [1, "1"] and algorithm == "RSA-OAEP-SHA256" and valid_base64?(key) do
          changeset
        else
          add_error(changeset, :public_key, "must be a valid RSA-OAEP public key")
        end

      _ ->
        add_error(changeset, :public_key, "must be a valid RSA-OAEP public key")
    end
  end

  defp payload_value(payload, string_key, atom_key) do
    Map.get(payload, string_key) || Map.get(payload, atom_key)
  end

  defp valid_base64?(value) when is_binary(value) do
    match?({:ok, decoded} when byte_size(decoded) > 32, Base.decode64(value))
  end

  defp valid_base64?(_), do: false
end
