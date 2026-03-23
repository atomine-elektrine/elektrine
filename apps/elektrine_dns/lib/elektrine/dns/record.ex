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
      :priority,
      :weight,
      :port,
      :flags,
      :tag,
      :zone_id
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:type, &normalize_type/1)
    |> validate_required([:name, :type, :ttl, :content, :zone_id])
    |> validate_inclusion(:type, @types)
    |> validate_number(:ttl, greater_than: 0, less_than_or_equal_to: 86_400)
    |> foreign_key_constraint(:zone_id)
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(""), do: "@"
  defp normalize_name(name), do: name |> String.trim() |> String.downcase()

  defp normalize_type(nil), do: nil
  defp normalize_type(type), do: type |> String.trim() |> String.upcase()
end
