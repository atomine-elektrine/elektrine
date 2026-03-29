defmodule Elektrine.DNS.Record do
  @moduledoc """
  Resource record inside a managed authoritative zone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(A AAAA CNAME TXT MX NS SRV CAA)

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
      :zone_id
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:type, &normalize_type/1)
    |> update_change(:source, &normalize_source/1)
    |> update_change(:service, &normalize_service/1)
    |> validate_required([:name, :type, :ttl, :content, :zone_id])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:source, ["user", "system"])
    |> validate_number(:ttl, greater_than: 0, less_than_or_equal_to: 86_400)
    |> foreign_key_constraint(:zone_id)
    |> unique_constraint(:managed_key, name: :dns_records_zone_managed_key_unique)
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(""), do: "@"
  defp normalize_name(name), do: name |> String.trim() |> String.downcase()

  defp normalize_type(nil), do: nil
  defp normalize_type(type), do: type |> String.trim() |> String.upcase()

  defp normalize_source(nil), do: nil
  defp normalize_source(source), do: source |> String.trim() |> String.downcase()

  defp normalize_service(nil), do: nil
  defp normalize_service(service), do: service |> String.trim() |> String.downcase()
end
