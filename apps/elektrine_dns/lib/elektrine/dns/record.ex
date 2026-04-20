defmodule Elektrine.DNS.Record do
  @moduledoc """
  Resource record inside a managed authoritative zone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.DNS.ServiceBinding

  @types ~w(A AAAA ALIAS CAA CNAME DNSKEY DS HTTPS MX NS SRV SSHFP SVCB TLSA TXT)

  schema "dns_records" do
    field :name, :string
    field :type, :string
    field :ttl, :integer, default: 300
    field :content, :string
    field :source, :string, default: "user"
    field :service, :string
    field :managed, :boolean, default: false
    field :managed_key, :string
    field :required, :boolean, default: false
    field :metadata, :map, default: %{}
    field :priority, :integer
    field :weight, :integer
    field :port, :integer
    field :flags, :integer
    field :tag, :string
    field :protocol, :integer
    field :algorithm, :integer
    field :key_tag, :integer
    field :digest_type, :integer
    field :usage, :integer
    field :selector, :integer
    field :matching_type, :integer

    belongs_to :zone, Elektrine.DNS.Zone

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :name,
      :type,
      :ttl,
      :content,
      :source,
      :service,
      :managed,
      :managed_key,
      :required,
      :metadata,
      :priority,
      :weight,
      :port,
      :flags,
      :tag,
      :protocol,
      :algorithm,
      :key_tag,
      :digest_type,
      :usage,
      :selector,
      :matching_type,
      :zone_id
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:type, &normalize_type/1)
    |> update_change(:source, &normalize_source/1)
    |> update_change(:service, &normalize_service/1)
    |> update_change(:content, &normalize_content/1)
    |> validate_required([:name, :type, :ttl, :content, :zone_id])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:source, ["user", "system"])
    |> validate_number(:ttl, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_cname_constraints()
    |> normalize_type_specific_content()
    |> validate_alias_target()
    |> validate_type_specific_fields()
    |> foreign_key_constraint(:zone_id)
    |> unique_constraint(:name, name: :dns_records_identity_unique)
    |> unique_constraint(:managed_key, name: :dns_records_zone_managed_key_unique)
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(""), do: "@"

  defp normalize_name(name) do
    case name |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> "@"
      "\\@" -> "@"
      normalized -> normalized
    end
  end

  defp normalize_type(nil), do: nil
  defp normalize_type(type), do: type |> String.trim() |> String.upcase()

  defp normalize_content(nil), do: nil
  defp normalize_content(content), do: String.trim(content)

  defp normalize_source(nil), do: nil
  defp normalize_source(source), do: source |> String.trim() |> String.downcase()

  defp normalize_service(nil), do: nil
  defp normalize_service(service), do: service |> String.trim() |> String.downcase()

  defp normalize_type_specific_content(changeset) do
    case {get_field(changeset, :type), get_field(changeset, :content)} do
      {"ALIAS", content} when is_binary(content) ->
        put_change(changeset, :content, normalize_hostname(content))

      {type, content} when type in ["DS", "TLSA", "SSHFP"] and is_binary(content) ->
        normalized = content |> String.replace(~r/\s+/, "") |> String.upcase()
        put_change(changeset, :content, normalized)

      {"DNSKEY", content} when is_binary(content) ->
        put_change(changeset, :content, String.replace(content, ~r/\s+/, ""))

      {type, content} when type in ["HTTPS", "SVCB"] and is_binary(content) ->
        case ServiceBinding.normalize_content(content) do
          {:ok, normalized} -> put_change(changeset, :content, normalized)
          {:error, _reason} -> changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_type_specific_fields(changeset) do
    case get_field(changeset, :type) do
      "MX" ->
        changeset
        |> validate_required([:priority])
        |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)

      "SRV" ->
        changeset
        |> validate_required([:priority, :weight, :port])
        |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_number(:weight, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_number(:port, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)

      "CAA" ->
        changeset
        |> validate_required([:flags, :tag])
        |> validate_number(:flags, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)

      "DNSKEY" ->
        changeset
        |> validate_required([:flags, :protocol, :algorithm])
        |> validate_number(:flags, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_number(:protocol, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_number(:algorithm, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_dnskey_content()

      "DS" ->
        changeset
        |> validate_required([:key_tag, :algorithm, :digest_type])
        |> validate_number(:key_tag, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_number(:algorithm, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_number(:digest_type, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_hex_content()

      "TLSA" ->
        changeset
        |> validate_required([:usage, :selector, :matching_type])
        |> validate_number(:usage, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_number(:selector, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_number(:matching_type,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 255
        )
        |> validate_hex_content()

      "SSHFP" ->
        changeset
        |> validate_required([:algorithm, :digest_type])
        |> validate_number(:algorithm, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_number(:digest_type, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
        |> validate_hex_content()

      type when type in ["HTTPS", "SVCB"] ->
        changeset
        |> validate_required([:priority])
        |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_service_binding_content()

      _ ->
        changeset
    end
  end

  defp validate_cname_constraints(changeset) do
    case {get_field(changeset, :type), get_field(changeset, :name)} do
      {"CNAME", "@"} ->
        add_error(changeset, :type, "cannot be used at the zone apex")

      {"ALIAS", name} when is_binary(name) and name != "@" ->
        add_error(changeset, :type, "can only be used at the zone apex")

      _ ->
        changeset
    end
  end

  defp validate_alias_target(changeset) do
    case {get_field(changeset, :type), get_field(changeset, :content)} do
      {"ALIAS", content} when is_binary(content) ->
        if Elektrine.DNS.public_hostname?(content) do
          changeset
        else
          add_error(changeset, :content, "must point to a public DNS hostname")
        end

      _ ->
        changeset
    end
  end

  defp normalize_hostname(hostname) do
    hostname
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp validate_dnskey_content(changeset) do
    validate_change(changeset, :content, fn :content, value ->
      case decode_base64(value) do
        {:ok, _} -> []
        :error -> [content: "must be valid base64 public key data"]
      end
    end)
  end

  defp validate_hex_content(changeset) do
    validate_change(changeset, :content, fn :content, value ->
      case decode_hex(value) do
        {:ok, _} -> []
        :error -> [content: "must be valid hexadecimal data"]
      end
    end)
  end

  defp validate_service_binding_content(changeset) do
    validate_change(changeset, :content, fn :content, value ->
      case ServiceBinding.parse_content(value) do
        {:ok, _parsed} -> []
        {:error, reason} -> [content: reason]
      end
    end)
  end

  defp decode_base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(value, padding: false)
    end
  end

  defp decode_base64(_), do: :error

  defp decode_hex(value) when is_binary(value), do: Base.decode16(value, case: :mixed)
  defp decode_hex(_), do: :error
end
