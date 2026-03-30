defmodule Elektrine.DNS do
  @moduledoc """
  Core context for Elektrine's managed DNS service.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.DNS.ManagedRecords
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.DNS.ZoneCache
  alias Elektrine.DNS.ZoneServiceConfig
  alias Elektrine.Repo

  @record_types ~w(A AAAA CAA CNAME DNSKEY DS MX NS SRV TLSA TXT)

  def list_user_zones(%User{id: user_id}), do: list_user_zones(user_id)

  def list_user_zones(user_id) when is_integer(user_id) do
    Zone
    |> where(user_id: ^user_id)
    |> order_by([z], asc: z.domain)
    |> preload([:records, :service_configs])
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
    |> preload([:records, :service_configs])
    |> Repo.one()
  end

  def get_zone(_, _), do: nil

  def get_zone_by_domain(domain) when is_binary(domain) do
    normalized = domain |> String.trim() |> String.downcase()

    Zone
    |> where([z], fragment("lower(?)", z.domain) == ^normalized)
    |> preload([:records, :service_configs])
    |> Repo.one()
  end

  def get_zone_by_domain(_), do: nil

  def create_zone(%User{id: user_id}, attrs), do: create_zone(user_id, attrs)

  def create_zone(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %Zone{}
    |> Zone.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
    |> case do
      {:ok, zone} -> {:ok, Repo.preload(zone, [:records, :service_configs])}
      error -> error
    end
    |> refresh_authority_cache_after_write()
  end

  def create_zone(_, _), do: {:error, :invalid_attributes}

  def create_record(%Zone{id: zone_id}, attrs), do: create_record(zone_id, attrs)

  def create_record(zone_id, attrs) when is_integer(zone_id) and is_map(attrs) do
    %Record{}
    |> Record.changeset(Map.put(attrs, "zone_id", zone_id))
    |> Repo.insert()
    |> refresh_authority_cache_after_write()
  end

  def create_record(_, _), do: {:error, :invalid_attributes}

  def update_zone(%Zone{} = zone, attrs) when is_map(attrs) do
    zone
    |> Zone.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, zone} -> {:ok, Repo.preload(zone, [:records, :service_configs])}
      error -> error
    end
    |> refresh_authority_cache_after_write()
  end

  def delete_zone(%Zone{} = zone) do
    zone
    |> Repo.delete()
    |> refresh_authority_cache_after_write()
  end

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
    |> refresh_authority_cache_after_write()
  end

  def delete_record(%Record{} = record) do
    record
    |> Repo.delete()
    |> refresh_authority_cache_after_write()
  end

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

  def list_zone_service_configs(%Zone{id: zone_id}), do: list_zone_service_configs(zone_id)

  def list_zone_service_configs(zone_id) when is_integer(zone_id) do
    ManagedRecords.list_service_configs(zone_id)
  end

  def list_zone_service_configs(_), do: []

  def get_zone_service_config(%Zone{id: zone_id}, service),
    do: get_zone_service_config(zone_id, service)

  def get_zone_service_config(zone_id, service) when is_integer(zone_id) do
    Repo.get_by(ZoneServiceConfig, zone_id: zone_id, service: normalize_service(service))
  end

  def get_zone_service_config(_, _), do: nil

  def apply_zone_service(%Zone{} = zone, service, attrs \\ %{}) do
    zone
    |> ManagedRecords.apply_service(service, attrs)
    |> refresh_authority_cache_after_write()
  end

  def disable_zone_service(%Zone{} = zone, service) do
    ManagedRecords.apply_service(zone, service, %{"enabled" => false})
  end

  def zone_service_health(%Zone{} = zone), do: ManagedRecords.service_health(zone)

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
    configured =
      Application.get_env(:elektrine, :dns, [])
      |> Keyword.get(:nameservers, [])

    case Enum.reject(configured, &is_nil_or_blank/1) do
      [] -> derive_nameservers()
      nameservers -> nameservers
    end
  end

  def authority_enabled? do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:authority_enabled, false)
  end

  def recursive_enabled? do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_enabled, false)
  end

  def recursive_upstreams do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_upstreams, [])
  end

  def recursive_root_hints do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_root_hints, [
      {{198, 41, 0, 4}, 53},
      {{170, 247, 170, 2}, 53},
      {{192, 33, 4, 12}, 53},
      {{199, 7, 91, 13}, 53},
      {{192, 203, 230, 10}, 53},
      {{192, 5, 5, 241}, 53},
      {{192, 112, 36, 4}, 53},
      {{198, 97, 190, 53}, 53},
      {{192, 36, 148, 17}, 53},
      {{192, 58, 128, 30}, 53},
      {{193, 0, 14, 129}, 53},
      {{199, 7, 83, 42}, 53},
      {{202, 12, 27, 33}, 53}
    ])
  end

  def recursive_timeout do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_timeout, 3_000)
  end

  def max_udp_payload do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:max_udp_payload, 1232)
  end

  def rate_limit_window_ms do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:rate_limit_window_ms, 1_000)
  end

  def udp_rate_limit_per_window do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:udp_rate_limit_per_window, 200)
  end

  def tcp_rate_limit_per_window do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:tcp_rate_limit_per_window, 50)
  end

  def udp_max_inflight do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:udp_max_inflight, 1024)
  end

  def tcp_max_inflight do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:tcp_max_inflight, 256)
  end

  def recursive_transport do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_transport, Elektrine.DNS.RecursiveTransport)
  end

  def dns_resolver do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:dns_resolver, :inet_res)
  end

  def recursive_allow_cidrs do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_allow_cidrs, [
      "127.0.0.0/8",
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
      "::1/128",
      "fc00::/7"
    ])
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
    case Application.get_env(:elektrine, :dns, []) |> Keyword.get(:soa_rname) do
      value when is_binary(value) and value != "" -> value
      _ -> derive_soa_rname()
    end
  end

  defp derive_nameservers do
    case primary_domain() do
      nil -> ["ns1.example.com", "ns2.example.com"]
      domain -> ["ns1.#{domain}", "ns2.#{domain}"]
    end
  end

  defp derive_soa_rname do
    case primary_domain() do
      nil -> "hostmaster.example.com"
      domain -> "hostmaster.#{domain}"
    end
  end

  defp primary_domain do
    Application.get_env(:elektrine, :primary_domain)
  end

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(value) when is_binary(value), do: String.trim(value) == ""
  defp is_nil_or_blank(_), do: false

  defp verify_nameservers(%Zone{domain: domain}) do
    expected = nameservers() |> Enum.map(&String.downcase/1) |> Enum.sort()

    resolved =
      domain
      |> String.to_charlist()
      |> dns_resolver().lookup(:in, :ns, timeout: 5_000)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_trailing(&1, "."))
      |> Enum.map(&String.downcase/1)
      |> Enum.sort()

    if expected == resolved,
      do: :ok,
      else: {:error, delegation_mismatch_message(expected, resolved)}
  rescue
    error -> {:error, "NS lookup failed for #{domain}: #{inspect(error)}"}
  end

  defp delegation_mismatch_message(expected, resolved) do
    "Delegation mismatch for the configured nameservers. Expected: #{format_nameserver_list(expected)}. Observed: #{format_nameserver_list(resolved)}."
  end

  defp format_nameserver_list([]), do: "none"
  defp format_nameserver_list(nameservers), do: Enum.join(nameservers, ", ")

  defp normalize_service(service) when is_binary(service), do: String.downcase(service)
  defp normalize_service(service), do: to_string(service) |> String.downcase()

  defp refresh_authority_cache_after_write({:ok, _result} = result) do
    refresh_authority_cache()
    result
  end

  defp refresh_authority_cache_after_write(result), do: result

  defp refresh_authority_cache do
    case Process.whereis(ZoneCache) do
      nil -> :ok
      _pid -> ZoneCache.refresh()
    end
  end
end
