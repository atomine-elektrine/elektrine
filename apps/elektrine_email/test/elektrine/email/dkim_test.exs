defmodule Elektrine.Email.DKIMTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.DKIM

  test "derives the DNS public key from the private key" do
    key_material = DKIM.generate_domain_key_material()

    assert {:ok, derived_public_key} = DKIM.public_key_from_private_key(key_material.private_key)

    assert DKIM.public_key_dns_value(derived_public_key) ==
             DKIM.public_key_dns_value(key_material.public_key)
  end

  test "DKIM TXT value prefers the private-key-derived public key" do
    key_material = DKIM.generate_domain_key_material()

    value = DKIM.dkim_value_from_material("STALEPUBLICKEY", key_material.private_key)

    assert value ==
             DKIM.dkim_value_from_material(key_material.public_key, key_material.private_key)

    refute value =~ "STALEPUBLICKEY"
  end

  test "DKIM TXT value falls back to the stored public key when private key is invalid" do
    assert DKIM.dkim_value_from_material("PUBLICKEY", "invalid") == "v=DKIM1; k=rsa; p=PUBLICKEY"
  end
end
