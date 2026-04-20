defmodule Elektrine.ActivityPub.Actor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Secrets.EncryptedString

  schema "activitypub_actors" do
    field :uri, :string
    field :username, :string
    field :domain, :string
    field :display_name, :string
    field :summary, :string
    field :avatar_url, :string
    field :header_url, :string
    field :inbox_url, :string
    field :outbox_url, :string
    field :followers_url, :string
    field :following_url, :string
    field :public_key, :string
    field :manually_approves_followers, :boolean, default: false
    field :actor_type, :string, default: "Person"
    field :last_fetched_at, :utc_datetime
    field :published_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :moderators_url, :string

    # Relationship to local community (if this actor represents a local community)
    belongs_to :community, Elektrine.Messaging.Conversation, foreign_key: :community_id

    timestamps()
  end

  @doc false
  def changeset(actor, attrs) do
    actor
    |> cast(attrs, [
      :uri,
      :username,
      :domain,
      :display_name,
      :summary,
      :avatar_url,
      :header_url,
      :inbox_url,
      :outbox_url,
      :followers_url,
      :following_url,
      :public_key,
      :manually_approves_followers,
      :actor_type,
      :last_fetched_at,
      :published_at,
      :metadata,
      :moderators_url,
      :community_id
    ])
    |> truncate_utc_datetimes([:last_fetched_at, :published_at])
    |> update_change(:metadata, &encrypt_metadata_private_key/1)
    |> validate_required([:uri, :username, :domain, :inbox_url])
    |> validate_inclusion(:actor_type, [
      "Person",
      "Group",
      "Organization",
      "Service",
      "Application"
    ])
    |> unique_constraint(:uri)
    |> unique_constraint([:username, :domain],
      name: :activitypub_actors_username_domain_unique_index
    )
    |> unique_constraint(:community_id)
  end

  def metadata_private_key(%__MODULE__{metadata: metadata}),
    do: decrypt_metadata_private_key(metadata)

  def metadata_private_key(_actor), do: nil

  def put_metadata_private_key(metadata, private_key) when is_binary(private_key) do
    metadata
    |> normalize_metadata()
    |> Map.put("private_key", encrypt_private_key(private_key))
  end

  def put_metadata_private_key(metadata, _private_key), do: normalize_metadata(metadata)

  defp encrypt_metadata_private_key(metadata) when is_map(metadata) do
    case Map.get(metadata, "private_key") || Map.get(metadata, :private_key) do
      private_key when is_binary(private_key) -> put_metadata_private_key(metadata, private_key)
      _ -> metadata
    end
  end

  defp encrypt_metadata_private_key(metadata), do: metadata

  defp decrypt_metadata_private_key(metadata) when is_map(metadata) do
    case Map.get(metadata, "private_key") || Map.get(metadata, :private_key) do
      private_key when is_binary(private_key) ->
        case EncryptedString.decrypt(private_key) do
          {:ok, decrypted} -> decrypted
          :error -> private_key
        end

      _ ->
        nil
    end
  end

  defp decrypt_metadata_private_key(_metadata), do: nil

  defp truncate_utc_datetimes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &Elektrine.Time.truncate/1)
    end)
  end

  defp encrypt_private_key(private_key) do
    case EncryptedString.encrypt(private_key) do
      {:ok, encrypted} -> encrypted
      :error -> private_key
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp normalize_metadata(_metadata), do: %{}
end
