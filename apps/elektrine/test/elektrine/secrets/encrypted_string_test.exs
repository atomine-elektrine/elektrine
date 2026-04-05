defmodule Elektrine.Secrets.EncryptedStringTest do
  use ExUnit.Case, async: true

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

  test "dumps encrypted strings with a versioned prefix" do
    assert {:ok, encrypted} = EncryptedString.dump("super-secret")

    assert EncryptedString.encrypted?(encrypted)
    refute encrypted == "super-secret"
  end

  test "loads encrypted strings back to plaintext" do
    {:ok, encrypted} = EncryptedString.dump("super-secret")

    assert {:ok, "super-secret"} = EncryptedString.load(encrypted)
  end

  test "loads legacy plaintext values unchanged" do
    assert {:ok, "legacy-plaintext"} = EncryptedString.load("legacy-plaintext")
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
