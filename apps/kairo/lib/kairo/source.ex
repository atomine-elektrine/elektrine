defmodule Kairo.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @source_types ~w(url text markdown html json file image pdf email rss_item timeline_post webhook)
  @statuses ~w(received stored processing compiled needs_review failed)

  schema "kairo_sources" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :project, Kairo.Project

    field :source_type, :string
    field :title, :string
    field :url, :string
    field :content, :string
    field :content_format, :string
    # Server-side at-rest encryption (Elektrine.Encryption, server-held per-user
    # key) of plaintext `content`. Applied automatically on ingest for non
    # zero-knowledge sources, mirroring how email/chat bodies are stored. The
    # plaintext `content` column is cleared once this is populated. Distinct from
    # `encrypted_content` below, which is the client zero-knowledge payload.
    field :content_encrypted, :map
    # Zero-knowledge: when `encrypted`, the body is client-encrypted into
    # `encrypted_content` (a `{version,algorithm,iv,ciphertext}` AES-256-GCM
    # payload under the user's Kairo subkey) and plaintext `content` is never
    # stored. The server cannot read it. Encrypted sources skip server processing.
    field :encrypted, :boolean, default: false
    field :encrypted_content, :map
    field :status, :string, default: "received"
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :raw_hash, :string
    field :error_message, :string
    field :ingested_at, :utc_datetime
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def source_types, do: @source_types
  def statuses, do: @statuses

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :user_id,
      :project_id,
      :source_type,
      :title,
      :url,
      :content,
      :content_format,
      :encrypted,
      :encrypted_content,
      :status,
      :tags,
      :metadata,
      :raw_hash,
      :error_message,
      :ingested_at,
      :processed_at
    ])
    |> normalize_tags()
    |> put_default_ingested_at()
    |> maybe_apply_encryption()
    |> validate_required([:user_id, :source_type, :status, :tags, :metadata, :ingested_at])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_source_payload()
    |> encrypt_content_at_rest()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
  end

  # Non zero-knowledge sources get their plaintext body encrypted at rest with
  # the server-held per-user key, the same treatment email and chat bodies get.
  # Runs after validation so content presence is still enforced on the plaintext.
  defp encrypt_content_at_rest(changeset) do
    user_id = get_field(changeset, :user_id)
    content = get_field(changeset, :content)

    if changeset.valid? and not get_field(changeset, :encrypted) and is_integer(user_id) and
         is_binary(content) and content != "" do
      changeset
      |> put_change(:content_encrypted, Elektrine.Encryption.encrypt(content, user_id))
      |> put_change(:content, nil)
    else
      changeset
    end
  end

  # For an encrypted source the server must never hold the plaintext body, and
  # the row must not enter the processing pipeline.
  defp maybe_apply_encryption(changeset) do
    if get_field(changeset, :encrypted) do
      changeset
      |> put_change(:content, nil)
      |> put_change(:status, "stored")
      |> validate_required([:encrypted_content])
      |> validate_encrypted_payload(:encrypted_content)
    else
      put_change(changeset, :encrypted_content, nil)
    end
  end

  defp validate_encrypted_payload(changeset, field) do
    case get_field(changeset, field) do
      %{} = payload ->
        if valid_encrypted_payload?(payload) do
          changeset
        else
          add_error(changeset, field, "must be a valid client-encrypted payload")
        end

      _ ->
        add_error(changeset, field, "must be a valid client-encrypted payload")
    end
  end

  defp valid_encrypted_payload?(payload) do
    algorithm = payload["algorithm"] || payload[:algorithm]
    iv = payload["iv"] || payload[:iv]
    ciphertext = payload["ciphertext"] || payload[:ciphertext]

    algorithm == "AES-GCM" and valid_base64_bytes?(iv, exact_size: 12) and
      valid_base64_bytes?(ciphertext, min_size: 1)
  end

  defp valid_base64_bytes?(value, opts) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} ->
        size = byte_size(bytes)

        size >= Keyword.get(opts, :min_size, 0) and
          (is_nil(Keyword.get(opts, :exact_size)) or size == Keyword.get(opts, :exact_size))

      :error ->
        false
    end
  end

  defp valid_base64_bytes?(_value, _opts), do: false

  defp normalize_tags(changeset) do
    tags =
      changeset
      |> get_field(:tags, [])
      |> List.wrap()
      |> Enum.flat_map(&split_tag/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    put_change(changeset, :tags, tags)
  end

  defp split_tag(tag) when is_binary(tag), do: String.split(tag, ",")
  defp split_tag(tag), do: [to_string(tag)]

  defp put_default_ingested_at(changeset) do
    case get_field(changeset, :ingested_at) do
      nil -> put_change(changeset, :ingested_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _value -> changeset
    end
  end

  defp validate_source_payload(changeset) do
    if [:title, :url, :content, :encrypted_content]
       |> Enum.any?(&(get_field(changeset, &1) |> present?())) do
      changeset
    else
      add_error(changeset, :content, "must include title, url, content, or encrypted_content")
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
