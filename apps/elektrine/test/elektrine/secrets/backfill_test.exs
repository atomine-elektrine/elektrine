defmodule Elektrine.Secrets.BackfillTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.SigningKey
  alias Elektrine.Email.CustomDomain
  alias Elektrine.Repo
  alias Elektrine.Secrets.Backfill
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

  test "dry run reports legacy plaintext secrets without updating them" do
    user = legacy_user_fixture()

    result = Backfill.run(dry_run: true)

    assert result.scanned >= 1
    assert result.updated == 0
    assert get_raw_user_field(user.id, "activitypub_private_key") == "legacy-private-key"
  end

  test "apply rewrites legacy plaintext secrets encrypted in place" do
    user = legacy_user_fixture()
    key_id = legacy_signing_key_fixture(user)
    domain_id = legacy_custom_domain_fixture(user)
    actor_id = legacy_actor_fixture()

    result = Backfill.run(dry_run: false)

    assert result.updated >= 4

    activitypub_private_key = get_raw_user_field(user.id, "activitypub_private_key")
    bluesky_app_password = get_raw_user_field(user.id, "bluesky_app_password")
    signing_private_key = get_raw_signing_key_field(key_id)
    dkim_private_key = get_raw_custom_domain_field(domain_id)

    assert EncryptedString.encrypted?(activitypub_private_key)
    assert EncryptedString.encrypted?(bluesky_app_password)
    assert EncryptedString.encrypted?(signing_private_key)
    assert EncryptedString.encrypted?(dkim_private_key)

    reloaded_user = Accounts.get_user!(user.id)
    reloaded_signing_key = Repo.get!(SigningKey, key_id)
    reloaded_domain = Repo.get!(CustomDomain, domain_id)
    reloaded_actor_metadata = get_raw_actor_metadata(actor_id)

    assert reloaded_user.activitypub_private_key == "legacy-private-key"
    assert reloaded_user.bluesky_app_password == "legacy-app-password"
    assert reloaded_signing_key.private_key == "legacy-signing-private-key"
    assert reloaded_domain.dkim_private_key == "legacy-dkim-private-key"
    assert EncryptedString.encrypted?(reloaded_actor_metadata["private_key"])

    assert Elektrine.ActivityPub.Actor.metadata_private_key(%Elektrine.ActivityPub.Actor{
             metadata: reloaded_actor_metadata
           }) ==
             "legacy-actor-private-key"
  end

  defp legacy_user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: "secretbackfill#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    Repo.query!(
      "UPDATE users SET activitypub_private_key = $1, bluesky_app_password = $2 WHERE id = $3",
      ["legacy-private-key", "legacy-app-password", user.id]
    )

    user
  end

  defp legacy_signing_key_fixture(user) do
    key_id = "https://example.com/users/#{user.username}#main-key"

    Repo.query!(
      "INSERT INTO signing_keys (key_id, user_id, public_key, private_key, inserted_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW())",
      [key_id, user.id, "legacy-public-key", "legacy-signing-private-key"]
    )

    key_id
  end

  defp legacy_custom_domain_fixture(user) do
    result =
      Repo.query!(
        "INSERT INTO email_custom_domains (domain, verification_token, dkim_selector, dkim_public_key, dkim_private_key, status, user_id, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW()) RETURNING id",
        [
          "secret#{System.unique_integer([:positive])}.example.com",
          "verify-token",
          "selector1",
          "legacy-dkim-public-key",
          "legacy-dkim-private-key",
          "pending",
          user.id
        ]
      )

    [[id]] = result.rows
    id
  end

  defp legacy_actor_fixture do
    result =
      Repo.query!(
        "INSERT INTO activitypub_actors (uri, username, domain, inbox_url, public_key, metadata, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6::jsonb, NOW(), NOW()) RETURNING id",
        [
          "https://example.com/actors/#{System.unique_integer([:positive])}",
          "actor#{System.unique_integer([:positive])}",
          "example.com",
          "https://example.com/inbox",
          "legacy-actor-public-key",
          Jason.encode!(%{"private_key" => "legacy-actor-private-key"})
        ]
      )

    [[id]] = result.rows
    id
  end

  defp get_raw_user_field(id, field) do
    Repo.query!("SELECT #{field} FROM users WHERE id = $1", [id]).rows
    |> List.first()
    |> List.first()
  end

  defp get_raw_signing_key_field(key_id) do
    Repo.query!("SELECT private_key FROM signing_keys WHERE key_id = $1", [key_id]).rows
    |> List.first()
    |> List.first()
  end

  defp get_raw_custom_domain_field(id) do
    Repo.query!("SELECT dkim_private_key FROM email_custom_domains WHERE id = $1", [id]).rows
    |> List.first()
    |> List.first()
  end

  defp get_raw_actor_metadata(id) do
    Repo.query!("SELECT metadata::text FROM activitypub_actors WHERE id = $1", [id]).rows
    |> List.first()
    |> List.first()
    |> decode_json_map()
  end

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode!(value) do
      decoded when is_map(decoded) -> decoded
      decoded when is_binary(decoded) -> Jason.decode!(decoded)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)
end
