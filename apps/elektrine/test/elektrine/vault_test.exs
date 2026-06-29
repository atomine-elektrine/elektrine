defmodule Elektrine.VaultTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Vault

  defp wrapped(opts \\ []) do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => Keyword.get(opts, :iterations, 600_000),
      "salt" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
      "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48))
    }
  end

  defp setup_attrs do
    %{"wrapped_dek" => wrapped(), "wrapped_dek_recovery" => wrapped()}
  end

  test "setup creates a master key and configured?/get reflect it" do
    user = user_fixture()

    refute Vault.configured?(user.id)
    assert Vault.get(user.id) == nil

    assert {:ok, master_key} = Vault.setup(user.id, setup_attrs())
    assert master_key.user_id == user.id
    assert Vault.configured?(user)
    assert %{wrapped_dek: %{}, wrapped_dek_recovery: %{}} = Vault.get(user)
  end

  test "setup refuses to replace an existing master key" do
    user = user_fixture()
    {:ok, _} = Vault.setup(user.id, setup_attrs())

    assert {:error, :already_configured} = Vault.setup(user.id, setup_attrs())
  end

  test "setup rejects malformed wrapped payloads" do
    user = user_fixture()

    bad = %{"wrapped_dek" => %{"algorithm" => "rot13"}, "wrapped_dek_recovery" => wrapped()}
    assert {:error, changeset} = Vault.setup(user.id, bad)
    assert %{wrapped_dek: _} = errors_on(changeset)

    short_iv = put_in(wrapped(), ["iv"], Base.encode64(:crypto.strong_rand_bytes(8)))

    assert {:error, _} =
             Vault.setup(user.id, %{
               "wrapped_dek" => short_iv,
               "wrapped_dek_recovery" => wrapped()
             })
  end

  test "rotate re-wraps without needing the prior MDK and only updates blobs" do
    user = user_fixture()
    {:ok, original} = Vault.setup(user.id, setup_attrs())

    new_attrs = setup_attrs()
    assert {:ok, rotated} = Vault.rotate(user, new_attrs)
    assert rotated.id == original.id
    assert rotated.wrapped_dek["salt"] == new_attrs["wrapped_dek"]["salt"]

    assert {:error, :not_configured} = Vault.rotate(user_fixture().id, setup_attrs())
  end

  test "reset removes the master key" do
    user = user_fixture()
    {:ok, _} = Vault.setup(user.id, setup_attrs())

    assert {:ok, true} = Vault.reset(user)
    refute Vault.configured?(user.id)
    assert {:ok, false} = Vault.reset(user.id)
  end
end
