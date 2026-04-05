defmodule Elektrine.ActivityPub.ActorSecretsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Secrets.EncryptedString

  setup do
    previous_master = Application.get_env(:elektrine, :encryption_master_secret)
    previous_salt = Application.get_env(:elektrine, :encryption_key_salt)

    Application.put_env(:elektrine, :encryption_master_secret, "test-master-secret-0123456789")
    Application.put_env(:elektrine, :encryption_key_salt, "test-key-salt-0123456789")

    on_exit(fn ->
      restore_env(:encryption_master_secret, previous_master)
      restore_env(:encryption_key_salt, previous_salt)
    end)

    :ok
  end

  test "changeset encrypts metadata private keys" do
    changeset =
      Actor.changeset(%Actor{}, %{
        uri: "https://example.com/actors/test",
        username: "test",
        domain: "example.com",
        inbox_url: "https://example.com/inbox",
        metadata: %{"private_key" => "plain-private-key"}
      })

    encrypted = Ecto.Changeset.get_change(changeset, :metadata)["private_key"]

    assert EncryptedString.encrypted?(encrypted)
  end

  test "metadata_private_key decrypts encrypted values and preserves plaintext fallback" do
    encrypted = Actor.put_metadata_private_key(%{}, "plain-private-key")

    assert Actor.metadata_private_key(%Actor{metadata: encrypted}) == "plain-private-key"

    assert Actor.metadata_private_key(%Actor{metadata: %{"private_key" => "legacy-plaintext"}}) ==
             "legacy-plaintext"
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
