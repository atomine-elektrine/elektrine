defmodule Elektrine.DNS do
  @moduledoc """
  Core context for Elektrine's managed authoritative DNS service.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.Repo

  @record_types ~w(A AAAA CAA CNAME MX NS SRV TXT)

  def list_user_zones(%User{id: user_id}), do: list_user_zones(user_id)

  def list_user_zones(user_id) when is_integer(user_id) do
    Zone
    |> where(user_id: ^user_id)
    |> order_by([z], asc: z.domain)
    |> preload(:records)
    |> Repo.all()
  end

  def list_user_zones(_), do: []

  def list_zone_records(zone_id) when is_integer(zone_id) do
    Record
    |> where(zone_id: ^zone_id)
    |> order_by([r], asc: r.name, asc: r.type)
    |> Repo.all()
  end

  def list_zone_records(_), do: []

  def get_zone!(id), do: Repo.get!(Zone, id)

  def get_zone(id, user_id) when is_integer(id) and is_integer(user_id) do
    Zone
    |> where([z], z.id == ^id and z.user_id == ^user_id)
    |> preload(:records)
    |> Repo.one()
  end

  def get_zone(_, _), do: nil

  def get_zone_by_domain(domain) when is_binary(domain) do
    normalized = domain |> String.trim() |> String.downcase()

    Zone
    |> where([z], fragment("lower(?)", z.domain) == ^normalized)
    |> preload(:records)
    |> Repo.one()
  end

  def get_zone_by_domain(_), do: nil

  def create_zone(%User{id: user_id}, attrs), do: create_zone(user_id, attrs)

  def create_zone(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %Zone{}
    |> Zone.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  def create_zone(_, _), do: {:error, :invalid_attributes}

  def create_record(%Zone{id: zone_id}, attrs), do: create_record(zone_id, attrs)

  def create_record(zone_id, attrs) when is_integer(zone_id) and is_map(attrs) do
    %Record{}
    |> Record.changeset(Map.put(attrs, "zone_id", zone_id))
    |> Repo.insert()
  end

  def create_record(_, _), do: {:error, :invalid_attributes}

  def update_zone(%Zone{} = zone, attrs) when is_map(attrs) do
    zone
    |> Zone.changeset(attrs)
    |> Repo.update()
  end

  def delete_zone(%Zone{} = zone), do: Repo.delete(zone)

  def change_zone(%Zone{} = zone, attrs \\ %{}), do: Zone.changeset(zone, attrs)

  def get_record(id, zone_id) when is_integer(id) and is_integer(zone_id) do
    Record
    |> where([r], r.id == ^id and r.zone_id == ^zone_id)
    |> Repo.one()
  end

  def get_record(_, _), do: nil

  def update_record(%Record{} = record, attrs) when is_map(attrs) do
    record
    |> Record.changeset(attrs)
    |> Repo.update()
  end

  def delete_record(%Record{} = record), do: Repo.delete(record)

  def change_record(%Record{} = record, attrs \\ %{}), do: Record.changeset(record, attrs)

  def new_zone_changeset(%User{id: user_id}), do: new_zone_changeset(user_id)

  def new_zone_changeset(user_id) when is_integer(user_id) do
    Zone.changeset(%Zone{}, %{
      user_id: user_id,
      default_ttl: default_ttl(),
      soa_mname: List.first(nameservers()),
      soa_rname: soa_rname(),
      soa_minimum: default_ttl()
    })
  end

  def new_record_changeset(zone_id) when is_integer(zone_id) do
    Record.changeset(%Record{}, %{zone_id: zone_id, ttl: default_ttl(), type: "A", name: "@"})
  end

  def default_ttl do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:default_ttl, 300)
  end

  def supported_record_types, do: @record_types

  def verify_zone(%Zone{} = zone) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with :ok <- verify_nameservers(zone) do
      update_zone(zone, %{
        status: "verified",
        verified_at: zone.verified_at || now,
        last_checked_at: now,
        last_error: nil
      })
    else
      {:error, reason} ->
        update_zone(zone, %{status: "pending", last_checked_at: now, last_error: reason})
    end
  end

  def zone_onboarding_records(%Zone{} = zone), do: Zone.nameserver_records(zone)

  def nameservers do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:nameservers, ["ns1.elektrine.com", "ns2.elektrine.com"])
  end

  def authority_enabled? do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:authority_enabled, false)
  end

  def udp_port do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:udp_port, 5300)
  end

  def tcp_port do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:tcp_port, 5300)
  end

  def soa_rname do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:soa_rname, "hostmaster.elektrine.com")
  end

  defp verify_nameservers(%Zone{domain: domain}) do
    expected = nameservers() |> Enum.map(&String.downcase/1) |> Enum.sort()

    resolved =
      domain
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :ns, timeout: 5_000)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_trailing(&1, "."))
      |> Enum.map(&String.downcase/1)
      |> Enum.sort()

    if expected == resolved,
      do: :ok,
      else: {:error, "Delegation does not match the Elektrine nameservers"}
  rescue
    error -> {:error, "NS lookup failed: #{inspect(error)}"}
  end
end
