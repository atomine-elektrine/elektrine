defmodule Elektrine.ActivityPub.SigningKey do
  @moduledoc "Manages cryptographic signing keys for ActivityPub federation.\n\nKeys are stored separately from users/actors to support:\n- Key rotation\n- Direct lookup by key_id (avoiding actor fetch for verification)\n- Key refresh with backoff to prevent hammering remote servers\n"
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor, as: RemoteActor
  alias Elektrine.Repo
  require Logger
  @min_refetch_interval 300
  @derive {Inspect, only: [:key_id, :user_id, :remote_actor_id, :inserted_at, :updated_at]}
  @primary_key {:key_id, :string, autogenerate: false}
  schema("signing_keys") do
    belongs_to(:user, User)
    belongs_to(:remote_actor, RemoteActor)
    field(:public_key, :string)
    field(:private_key, :string)
    timestamps()
  end

  @doc "Changeset for creating/updating a remote signing key.\n"
  def remote_changeset(signing_key \\ %__MODULE__{}, attrs) do
    signing_key
    |> cast(attrs, [:key_id, :remote_actor_id, :public_key])
    |> validate_required([:key_id, :remote_actor_id, :public_key])
    |> unique_constraint(:key_id, name: :signing_keys_pkey)
  end

  @doc "Changeset for creating a local user's signing key.\n"
  def local_changeset(signing_key \\ %__MODULE__{}, attrs) do
    signing_key
    |> cast(attrs, [:key_id, :user_id, :public_key, :private_key])
    |> validate_required([:key_id, :user_id, :public_key, :private_key])
    |> unique_constraint(:key_id, name: :signing_keys_pkey)
  end

  @doc "Gets a signing key by its key_id.\nReturns nil if not found.\n"
  def get_by_key_id(key_id) do
    Repo.get(__MODULE__, key_id)
  end

  @doc "Gets a signing key by key_id, fetching from remote if not found.\nReturns {:ok, signing_key} or {:error, reason}.\n"
  def get_or_fetch_by_key_id(key_id) do
    case get_by_key_id(key_id) do
      nil -> fetch_remote_key(key_id)
      key -> {:ok, key}
    end
  end

  @doc "Refreshes a signing key if it's old enough.\nImplements backoff to prevent excessive fetching.\n"
  def refresh_by_key_id(key_id) do
    case get_by_key_id(key_id) do
      nil ->
        {:error, :not_found}

      key ->
        seconds_since_update =
          NaiveDateTime.diff(NaiveDateTime.utc_now(), key.updated_at, :second)

        if seconds_since_update >= @min_refetch_interval do
          fetch_remote_key(key_id)
        else
          Logger.debug(
            "Key #{key_id} too fresh to refresh (#{seconds_since_update}s < #{@min_refetch_interval}s)"
          )

          {:error, :too_young}
        end
    end
  end

  @doc "Fetches a remote key by key_id.\nThe key_id is typically the actor's URI with #main-key appended.\n"
  def fetch_remote_key(key_id) do
    Logger.debug("Fetching remote key: #{key_id}")
    actor_uri = extract_actor_uri(key_id)

    case Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, actor} ->
        store_remote_key(key_id, actor)

      {:error, reason} ->
        Logger.debug("Failed to fetch actor for key #{key_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp store_remote_key(key_id, %RemoteActor{} = actor) do
    if is_nil(actor.public_key) or actor.public_key == "" do
      {:error, :no_public_key}
    else
      attrs = %{key_id: key_id, remote_actor_id: actor.id, public_key: actor.public_key}

      %__MODULE__{}
      |> remote_changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:public_key, :updated_at]},
        conflict_target: :key_id,
        returning: true
      )
    end
  end

  @doc "Creates or updates a signing key for a local user.\n"
  def upsert_local_key(user, public_key, private_key) do
    key_id = local_key_id(user)
    attrs = %{key_id: key_id, user_id: user.id, public_key: public_key, private_key: private_key}

    %__MODULE__{}
    |> local_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:public_key, :private_key, :updated_at]},
      conflict_target: :key_id,
      returning: true
    )
  end

  @doc "Gets the signing key for a local user.\n"
  def get_for_user(user_id) do
    from(sk in __MODULE__, where: sk.user_id == ^user_id) |> Repo.one()
  end

  @doc "Gets the signing key for a remote actor.\n"
  def get_for_remote_actor(remote_actor_id) do
    from(sk in __MODULE__, where: sk.remote_actor_id == ^remote_actor_id) |> Repo.one()
  end

  @doc "Generates the key_id for a local user.\nUses ActivityPub.instance_url() to ensure consistency with the actor document.\n"
  def local_key_id(%User{} = user) do
    base_url = Elektrine.ActivityPub.instance_url()
    "#{base_url}/users/#{user.username}#main-key"
  end

  def local_key_id(username) when is_binary(username) do
    base_url = Elektrine.ActivityPub.instance_url()
    "#{base_url}/users/#{username}#main-key"
  end

  @doc "Extracts the actor URI from a key_id.\n"
  def extract_actor_uri(key_id) do
    key_id |> String.split("#") |> List.first()
  end

  @doc "Decodes the public key from PEM format.\nReturns {:ok, decoded_key} or {:error, reason}.\n"
  def public_key_decoded(%__MODULE__{public_key: pem}) when is_binary(pem) do
    [entry] = :public_key.pem_decode(pem)
    decoded = :public_key.pem_entry_decode(entry)
    {:ok, decoded}
  rescue
    e ->
      Logger.error("Failed to decode public key: #{inspect(e)}")
      {:error, :invalid_key}
  end

  def public_key_decoded(_) do
    {:error, :no_key}
  end

  @doc "Decodes the private key from PEM format.\nReturns {:ok, decoded_key} or {:error, reason}.\n"
  def private_key_decoded(%__MODULE__{private_key: pem}) when is_binary(pem) do
    [entry] = :public_key.pem_decode(pem)
    decoded = :public_key.pem_entry_decode(entry)
    {:ok, decoded}
  rescue
    e ->
      Logger.error("Failed to decode private key: #{inspect(e)}")
      {:error, :invalid_key}
  end

  def private_key_decoded(_) do
    {:error, :no_key}
  end

  @doc "Generates a new RSA key pair.\nReturns {public_key_pem, private_key_pem}.\n"
  def generate_key_pair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    public_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    {public_pem, private_pem}
  end

  @doc "Signs a string with a signing key.\nReturns base64-encoded signature.\n"
  def sign(%__MODULE__{} = key, data) do
    case private_key_decoded(key) do
      {:ok, private_key} ->
        signature = :public_key.sign(data, :sha256, private_key)
        {:ok, Base.encode64(signature)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Verifies a signature with a signing key.\nReturns true if valid, false otherwise.\n"
  def verify(%__MODULE__{} = key, data, signature) do
    case public_key_decoded(key) do
      {:ok, public_key} ->
        case Base.decode64(signature) do
          {:ok, decoded_sig} -> :public_key.verify(data, :sha256, decoded_sig, public_key)
          :error -> false
        end

      {:error, _} ->
        false
    end
  end
end
