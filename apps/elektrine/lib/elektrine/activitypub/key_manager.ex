defmodule Elektrine.ActivityPub.KeyManager do
  @moduledoc """
  Manages ActivityPub RSA keys for users and actors.
  Generates keys lazily when first needed.
  """

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.Repo

  @doc """
  Ensures a user or actor has ActivityPub keys, generating them if needed.
  Returns the entity with keys loaded.

  Accepts a User struct, Actor struct, or user ID.
  """
  def ensure_user_has_keys(%ActivityPub.Actor{} = actor) do
    private_key = get_in(actor.metadata, ["private_key"])

    if actor.public_key && private_key do
      # Actor already has keys
      {:ok, actor}
    else
      # Generate keys for actor (local actors like relay)
      generate_keys_for_actor(actor)
    end
  end

  def ensure_user_has_keys(%Accounts.User{} = user) do
    if user.activitypub_public_key && user.activitypub_private_key do
      # Keys already exist
      {:ok, user}
    else
      # Generate keys
      generate_keys_for_user(user)
    end
  end

  def ensure_user_has_keys(user_id) when is_integer(user_id) do
    user = Accounts.get_user!(user_id)
    ensure_user_has_keys(user)
  end

  defp generate_keys_for_user(user) do
    Logger.info("Generating ActivityPub keys for user: #{user.username}")

    {public_key, private_key} = HTTPSignature.generate_key_pair()

    user
    |> Ecto.Changeset.change(%{
      activitypub_public_key: public_key,
      activitypub_private_key: private_key
    })
    |> Repo.update()
  rescue
    e ->
      Logger.error("Failed to generate keys for user #{user.username}: #{inspect(e)}")
      {:error, :key_generation_failed}
  end

  defp generate_keys_for_actor(actor) do
    Logger.info("Generating ActivityPub keys for actor: #{actor.uri}")

    {public_key, private_key} = HTTPSignature.generate_key_pair()

    # Store private key in metadata, public key in dedicated field
    updated_metadata = Map.put(actor.metadata || %{}, "private_key", private_key)

    actor
    |> Ecto.Changeset.change(%{
      public_key: public_key,
      metadata: updated_metadata
    })
    |> Repo.update()
  rescue
    e ->
      Logger.error("Failed to generate keys for actor #{actor.uri}: #{inspect(e)}")
      {:error, :key_generation_failed}
  end
end
