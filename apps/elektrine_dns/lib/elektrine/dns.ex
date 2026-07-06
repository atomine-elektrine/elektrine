defmodule Elektrine.DNS do
  @moduledoc """
  Core context for Elektrine's managed DNS service.
  """

  import Ecto.Changeset, only: [add_error: 3, change: 1]
  import Ecto.Query, warn: false

  require Logger

  alias Elektrine.Accounts.BuiltInSubdomain
  alias Elektrine.DNS.DomainHealth
  alias Elektrine.DNS.ManagedRecords
  alias Elektrine.DNS.Packet
  alias Elektrine.DNS.QueryStat
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.DNS.ZoneCache
  alias Elektrine.DNS.ZoneServiceConfig
  alias Elektrine.Domains
  alias Elektrine.Repo

  @record_types ~w(A AAAA ALIAS CAA CNAME DNSKEY DS HTTPS MX NS SRV SSHFP SVCB TLSA TXT)
  @builtin_user_zone_apex_managed_key "system:profile-apex"
  @builtin_user_zone_managed_service "system"
  @profile_wildcard_managed_key_a "system:profile-wildcard-a"
  @profile_wildcard_managed_key_aaaa "system:profile-wildcard-aaaa"
  @builtin_user_zone_forbidden_types ~w(ALIAS DNSKEY DS NS TLSA)
  @builtin_user_zone_allowed_apex_types ~w(CAA TXT)
  @builtin_user_zone_modes BuiltInSubdomain.modes()
  @user_schema :"Elixir.Elektrine.Accounts.User"
  @nameserver_label_pairs [
    ~w(rose mint),
    ~w(lumen quartz),
    ~w(ember slate),
    ~w(onyx pearl),
    ~w(cobalt amber),
    ~w(violet cedar),
    ~w(indigo copper),
    ~w(silver olive)
  ]

  def list_user_zones(%{id: user_id} = user) when is_integer(user_id) do
    _ = ensure_builtin_user_zone(user)

    user_id
    |> list_user_zones()
    |> sort_user_zones(builtin_user_zone_domain(user))
  end

  def list_user_zones(user_id) when is_integer(user_id) do
    Zone
    |> where(user_id: ^user_id)
    |> order_by([z], asc: z.domain)
    |> preload([:records, :service_configs])
    |> Repo.all()
  end

  def list_user_zones(_), do: []

  def ensure_builtin_user_zone(%{id: user_id} = user) when is_integer(user_id) do
    case builtin_user_zone_domain(user) do
      nil -> {:error, :invalid_user}
      domain -> ensure_builtin_user_zone(user, domain)
    end
  end

  def ensure_builtin_user_zone(_), do: {:error, :invalid_user}

  def builtin_user_zone_domain(%{handle: handle, username: username}) do
    label =
      (handle || username)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    base_domain = Domains.primary_profile_domain()

    if label == "" or not public_hostname?(base_domain) do
      nil
    else
      label <> "." <> base_domain
    end
  end

  def builtin_user_zone_domain(_), do: nil

  def builtin_user_zone?(%Zone{} = zone, %{id: user_id} = user) when is_integer(user_id) do
    zone.user_id == user_id and zone.domain == builtin_user_zone_domain(user)
  end

  def builtin_user_zone_mode(%{built_in_subdomain_mode: _} = user),
    do: BuiltInSubdomain.mode(user)

  def builtin_user_zone_mode(%Zone{} = zone) do
    case zone.user_id && Repo.get(@user_schema, zone.user_id) do
      nil -> "platform"
      user -> builtin_user_zone_mode(user)
    end
  end

  def builtin_user_zone_mode(_), do: "platform"

  def builtin_user_zone_hosted_by_platform?(user_or_zone),
    do: builtin_user_zone_mode(user_or_zone) == "platform"

  def update_builtin_user_zone_mode(user, mode) when mode in @builtin_user_zone_modes do
    if user_schema?(user) do
      update_user_builtin_zone_mode(user, mode)
    else
      {:error, :invalid_user}
    end
  end

  def update_builtin_user_zone_mode(user, _mode) do
    if user_schema?(user), do: {:error, :invalid_mode}, else: {:error, :invalid_user}
  end

  defp update_user_builtin_zone_mode(user, mode) do
    user
    |> Ecto.Changeset.change(%{built_in_subdomain_mode: mode})
    |> Repo.update()
    |> case do
      {:ok, updated_user} ->
        with :ok <- validate_platform_handoff(updated_user),
             {:ok, _zone} <- ensure_builtin_user_zone(updated_user) do
          {:ok, updated_user}
        else
          {:error, reason} ->
            _ =
              Repo.update(
                Ecto.Changeset.change(updated_user, %{
                  built_in_subdomain_mode: builtin_user_zone_mode(user)
                })
              )

            {:error, reason}
        end

      error ->
        error
    end
  end

  def builtin_user_zone?(%Zone{} = zone) do
    case zone.user_id && Repo.get(@user_schema, zone.user_id) do
      nil -> false
      user -> builtin_user_zone?(zone, user)
    end
  end

  def builtin_user_zone?(_), do: false

  def repair_builtin_user_zone_records(%Zone{} = zone) do
    if builtin_user_zone?(zone) do
      ensure_builtin_user_zone_records(zone, refresh_cache?: false)
    else
      {:ok, zone}
    end
  end

  def repair_builtin_user_zone_records(_), do: {:error, :invalid_zone}

  @doc """
  Ensures a proxied wildcard record (`*.<base>`) exists in every configured
  profile base-domain zone this server is authoritative for.

  This is the catch-all that lets every built-in profile subdomain
  (`username.<base>`) resolve to the edge even when the user has never
  provisioned their own built-in zone. Per-user zones still take precedence,
  because the resolver matches the most specific zone first.

  Idempotent. Returns a list of `{domain, result}` tuples where `result` is
  `:ok`, `{:error, :zone_not_found}` (the base domain is not a managed zone
  here), or `{:error, :no_edge_proxy_ipv4}` (no edge address is configured to
  point the wildcard at).
  """
  def ensure_profile_subdomain_wildcards do
    domains =
      [Domains.primary_profile_domain() | Domains.configured_profile_base_domains()]
      |> Enum.map(&normalize_zone_host/1)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    results = Enum.map(domains, &ensure_profile_wildcard_for_domain/1)

    if Enum.any?(results, fn {_domain, result} -> result == :ok end) do
      ZoneCache.refresh_async()
    end

    results
  end

  defp ensure_profile_wildcard_for_domain(domain) do
    if edge_proxy_ipv4_addresses() == [] do
      {domain, {:error, :no_edge_proxy_ipv4}}
    else
      case get_zone_by_domain(domain) do
        %Zone{} = zone ->
          upsert_profile_wildcard_records(zone)
          {domain, :ok}

        nil ->
          {domain, {:error, :zone_not_found}}
      end
    end
  end

  defp upsert_profile_wildcard_records(%Zone{} = zone) do
    upsert_profile_wildcard_record(
      zone,
      "A",
      @profile_wildcard_managed_key_a,
      List.first(edge_proxy_ipv4_addresses())
    )

    case List.first(edge_proxy_ipv6_addresses()) do
      nil ->
        delete_profile_wildcard_record(zone, @profile_wildcard_managed_key_aaaa)

      ipv6 ->
        upsert_profile_wildcard_record(zone, "AAAA", @profile_wildcard_managed_key_aaaa, ipv6)
    end

    :ok
  end

  defp upsert_profile_wildcard_record(%Zone{} = zone, type, managed_key, placeholder_content) do
    attrs = %{
      zone_id: zone.id,
      name: "*",
      type: type,
      ttl: default_ttl(),
      content: placeholder_content,
      source: "system",
      service: @builtin_user_zone_managed_service,
      managed: true,
      managed_key: managed_key,
      required: true,
      proxied: true,
      metadata: %{"label" => "Profile subdomain catch-all"}
    }

    case Repo.get_by(Record, zone_id: zone.id, managed_key: managed_key) do
      %Record{} = record ->
        record |> Record.changeset(attrs) |> Repo.insert_or_update!()

      nil ->
        %Record{} |> Record.changeset(attrs) |> Repo.insert!()
    end
  end

  defp delete_profile_wildcard_record(%Zone{} = zone, managed_key) do
    case Repo.get_by(Record, zone_id: zone.id, managed_key: managed_key) do
      %Record{} = record -> Repo.delete!(record)
      nil -> :ok
    end
  end

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

  def web_force_https_for_host(host) when is_binary(host) do
    host
    |> normalize_zone_host()
    |> get_zone_by_domain()
    |> case do
      %Zone{force_https: force_https} -> force_https == true
      _ -> false
    end
  end

  def web_force_https_for_host(_), do: false

  def health_status do
    zone_cache_running? = Process.whereis(Elektrine.DNS.ZoneCache) != nil

    status =
      if zone_cache_running? do
        :ok
      else
        :error
      end

    %{
      status: status,
      zone_cache_running: zone_cache_running?,
      nameservers_configured: true,
      authority_enabled: authority_enabled?(),
      recursive_enabled: recursive_enabled?()
    }
  end

  def domain_health(%Zone{} = zone), do: DomainHealth.analyze(zone)

  def domain_health(_), do: DomainHealth.analyze(nil)

  def create_zone(%{id: user_id}, attrs) when is_integer(user_id), do: create_zone(user_id, attrs)

  def create_zone(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %Zone{}
    |> Zone.changeset(create_zone_attrs(attrs, user_id))
    |> Repo.insert()
    |> case do
      {:ok, zone} ->
        zone
        |> assign_nameserver_set_on_create()
        |> Repo.preload([:records, :service_configs])
        |> then(&{:ok, &1})

      error ->
        error
    end
    |> refresh_authority_cache_after_write()
    |> maybe_ensure_profile_wildcards_after_zone_write()
  end

  def create_zone(_, _), do: {:error, :invalid_attributes}

  def create_record(%Zone{} = zone, attrs) when is_map(attrs) do
    normalized_attrs = normalize_record_attrs(attrs, zone.domain)

    with :ok <- validate_zone_record_write(zone, normalized_attrs) do
      zone_domain = zone.domain

      %Record{}
      |> Record.changeset(
        normalize_record_attrs(Map.put(normalized_attrs, "zone_id", zone.id), zone_domain)
      )
      |> Repo.insert()
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def create_record(zone_id, attrs) when is_integer(zone_id) and is_map(attrs) do
    case Repo.get(Zone, zone_id) do
      %Zone{} = zone -> create_record(zone, attrs)
      nil -> {:error, :not_found}
    end
  end

  def create_record(_, _), do: {:error, :invalid_attributes}

  def update_zone(%Zone{} = zone, attrs) when is_map(attrs) do
    if builtin_user_zone?(zone) and Map.has_key?(attrs, "domain") do
      {:error, add_error(change(zone), :domain, "is managed by Elektrine")}
    else
      zone
      |> Zone.changeset(public_zone_attrs(attrs))
      |> Repo.update()
      |> case do
        {:ok, zone} -> {:ok, Repo.preload(zone, [:records, :service_configs])}
        error -> error
      end
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def delete_zone(%Zone{} = zone) do
    if builtin_user_zone?(zone) do
      {:error,
       add_error(change(zone), :domain, "is the built-in profile subdomain and cannot be deleted")}
    else
      zone
      |> Repo.delete()
      |> refresh_authority_cache_after_write()
    end
  end

  def change_zone(%Zone{} = zone, attrs \\ %{}), do: Zone.changeset(zone, attrs)

  def get_record(id, zone_id) when is_integer(id) and is_integer(zone_id) do
    Record
    |> where([r], r.id == ^id and r.zone_id == ^zone_id)
    |> Repo.one()
  end

  def get_record(_, _), do: nil

  def update_record(%Record{} = record, attrs) when is_map(attrs) do
    zone_domain = zone_domain(record.zone_id)
    zone = Repo.get(Zone, record.zone_id)
    normalized_attrs = normalize_record_attrs(public_record_attrs(attrs), zone_domain)

    with :ok <- validate_record_mutation(record, :update),
         :ok <-
           validate_zone_record_write(
             zone,
             Map.merge(record_write_attrs(record), normalized_attrs)
           ) do
      record
      |> Record.changeset(normalized_attrs)
      |> Repo.update()
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def delete_record(%Record{} = record) do
    with :ok <- validate_record_mutation(record, :delete) do
      record
      |> Repo.delete()
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def change_record(%Record{} = record, attrs \\ %{}) do
    record
    |> Map.put(:private, Record.private?(record))
    |> Map.put(:proxied, Record.proxied?(record))
    |> Map.put(:proxy_origin_scheme, Record.proxy_origin_scheme(record))
    |> Map.put(:proxy_origin_port, Record.proxy_origin_port(record))
    |> Map.put(:proxy_origin_host_header, Record.proxy_origin_host_header(record))
    |> Map.put(:proxy_atomine_gate, Record.proxy_atomine_gate?(record))
    |> Record.changeset(attrs)
  end

  def new_zone_changeset(%{id: user_id}) when is_integer(user_id), do: new_zone_changeset(user_id)

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
    zone_id
    |> list_zone_service_configs()
    |> Enum.find(&(&1.service == normalize_service(service)))
  end

  def get_zone_service_config(_, _), do: nil

  def apply_zone_service(%Zone{} = zone, service, attrs \\ %{}) do
    if builtin_user_zone?(zone) do
      {:error,
       add_error(
         change(zone),
         :domain,
         "managed service bundles are disabled for the built-in profile subdomain"
       )}
    else
      zone
      |> ManagedRecords.apply_service(service, attrs)
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def disable_zone_service(%Zone{} = zone, service) do
    if builtin_user_zone?(zone) do
      {:error,
       add_error(
         change(zone),
         :domain,
         "managed service bundles are disabled for the built-in profile subdomain"
       )}
    else
      zone
      |> ManagedRecords.apply_service(service, %{"enabled" => false})
      |> refresh_authority_cache_after_write(touch_zone: true)
    end
  end

  def zone_service_health(%Zone{} = zone), do: ManagedRecords.service_health(zone)

  def public_service_settings(service, settings),
    do: ManagedRecords.public_settings(service, settings)

  def builtin_user_zone_reserved_hint(%Zone{} = zone) do
    if builtin_user_zone?(zone) and builtin_user_zone_hosted_by_platform?(zone) do
      %{apex_record_type: "ALIAS", apex_target: Domains.profile_custom_domain_routing_target()}
    else
      nil
    end
  end

  defp normalize_zone_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
    |> then(fn
      "www." <> domain -> domain
      domain -> domain
    end)
  end

  def default_ttl do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:default_ttl, 300)
  end

  def edge_proxy_ipv4_addresses do
    configured_edge_proxy_addresses(:edge_proxy_ipv4_addresses, :a)
  end

  def edge_proxy_ipv6_addresses do
    configured_edge_proxy_addresses(:edge_proxy_ipv6_addresses, :aaaa)
  end

  def edge_proxy_hostname do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:edge_proxy_hostname)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> Domains.profile_custom_domain_edge_target()
    end
    |> normalize_edge_proxy_hostname()
  end

  defp configured_edge_proxy_addresses(config_key, fallback_type) do
    configured =
      Application.get_env(:elektrine, :dns, [])
      |> Keyword.get(config_key, [])
      |> normalize_edge_proxy_addresses()

    if configured == [], do: resolve_edge_proxy_addresses(fallback_type), else: configured
  end

  defp normalize_edge_proxy_addresses(addresses) do
    addresses
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp resolve_edge_proxy_addresses(type) when type in [:a, :aaaa] do
    case edge_proxy_hostname() do
      nil ->
        []

      hostname ->
        hostname
        |> String.to_charlist()
        |> dns_resolver().lookup(:in, type, timeout: 3_000)
        |> Enum.map(&normalize_lookup_address/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  rescue
    _ -> []
  end

  defp normalize_lookup_address({_, _, _, _} = address), do: :inet.ntoa(address) |> to_string()
  defp normalize_lookup_address(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp normalize_lookup_address(value) when is_binary(value), do: String.trim(value)

  defp normalize_lookup_address(value) when is_list(value),
    do: value |> to_string() |> String.trim()

  defp normalize_lookup_address(_), do: nil

  defp normalize_edge_proxy_hostname(nil), do: nil

  defp normalize_edge_proxy_hostname(hostname) do
    hostname = hostname |> String.trim() |> String.trim_trailing(".") |> String.downcase()
    if hostname == "", do: nil, else: hostname
  end

  def supported_record_types, do: @record_types

  def proxied_host?(host) when is_binary(host) do
    match?({:ok, _origin}, proxied_origin_for_host(host))
  end

  def proxied_host?(_), do: false

  def proxied_origin_for_host(host) when is_binary(host) do
    normalized_host = normalize_proxy_host(host)

    with %Zone{} = zone <- proxied_zone_for_host(normalized_host),
         %Record{} = record <- proxied_record_for_host(zone, normalized_host) do
      {:ok, proxied_origin(zone, record, normalized_host)}
    else
      _ -> {:error, :not_found}
    end
  end

  def proxied_origin_for_host(_), do: {:error, :not_found}

  def scan_existing_zone(domain) when is_binary(domain) do
    normalized_domain = domain |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if public_hostname?(normalized_domain) do
      nameservers = lookup_dns_values(normalized_domain, :ns, timeout: 5_000)

      %{
        domain: normalized_domain,
        nameservers: nameservers,
        delegated_to_elektrine: delegated_to_elektrine?(nameservers),
        provider_hint: provider_hint(nameservers),
        records:
          [
            scan_record_entry("@", "A", lookup_dns_values(normalized_domain, :a, timeout: 3_000)),
            scan_record_entry(
              "@",
              "AAAA",
              lookup_dns_values(normalized_domain, :aaaa, timeout: 3_000)
            ),
            scan_record_entry(
              "@",
              "CNAME",
              lookup_dns_values(normalized_domain, :cname, timeout: 3_000)
            ),
            scan_record_entry(
              "@",
              "MX",
              lookup_dns_values(normalized_domain, :mx, timeout: 3_000)
            ),
            scan_record_entry(
              "www",
              "CNAME",
              lookup_dns_values("www." <> normalized_domain, :cname, timeout: 3_000)
            ),
            scan_record_entry(
              "www",
              "A",
              lookup_dns_values("www." <> normalized_domain, :a, timeout: 3_000)
            )
          ]
          |> Enum.reject(&is_nil/1)
      }
    else
      nil
    end
  end

  def scan_existing_zone(_), do: nil

  def verify_zone(%Zone{} = zone) do
    if builtin_user_zone?(zone) do
      ensure_builtin_user_zone_records(zone)
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case verify_nameservers(zone) do
        :ok ->
          update_zone_verification(zone, %{
            status: "verified",
            verified_at: zone.verified_at || now,
            last_checked_at: now,
            last_error: nil
          })

        {:error, reason} ->
          update_zone_verification(zone, %{
            status: "pending",
            last_checked_at: now,
            last_error: reason
          })
      end
    end
  end

  def zone_onboarding_records(%Zone{} = zone) do
    if builtin_user_zone?(zone), do: [], else: Zone.nameserver_records(zone)
  end

  def assigned_nameservers(%Zone{} = zone) do
    case nameserver_sets() do
      [] -> nameservers()
      sets -> Enum.at(sets, zone_nameserver_set(zone, length(sets)))
    end
  end

  def assigned_nameservers(_), do: nameservers()

  def assigned_nameserver_address_records(host, qtype) when is_binary(host) do
    normalized_host = normalize_hostname(host)
    qtype = normalize_query_type(qtype)

    case assigned_nameserver_base(normalized_host) do
      nil ->
        []

      base ->
        []
        |> maybe_add_nameserver_address_records(normalized_host, base, :a, "A", qtype)
        |> maybe_add_nameserver_address_records(normalized_host, base, :aaaa, "AAAA", qtype)
    end
  end

  def assigned_nameserver_address_records(_, _), do: []

  def nameservers do
    configured =
      Application.get_env(:elektrine, :dns, [])
      |> Keyword.get(:nameservers, [])

    case Enum.reject(configured, &nil_or_blank?/1) do
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

  def alias_resolver do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:alias_resolver, :inet_res)
  end

  def zone_cache_refresh_interval_ms do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:zone_cache_refresh_interval_ms, 60_000)
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

  def track_query(%{zone: %Zone{id: zone_id}, authoritative: true} = result, transport)
      when transport in ["udp", "tcp"] do
    rcode = normalize_dns_metric_value(result.rcode)

    attrs = %{
      zone_id: zone_id,
      query_date: Date.utc_today(),
      query_hour: DateTime.utc_now() |> DateTime.truncate(:second) |> truncate_to_hour(),
      qname: normalize_dns_metric_name(result.qname, result.zone.domain, rcode),
      qtype: normalize_dns_metric_value(result.qtype),
      rcode: rcode,
      transport: transport,
      query_count: 1
    }

    Elektrine.DNS.QueryStatsBuffer.increment(attrs)

    :ok
  rescue
    _ -> :ok
  end

  def track_query(_result, _transport), do: :ok

  defp flush_query_stats_buffer do
    Elektrine.DNS.QueryStatsBuffer.flush()
  rescue
    _ -> :ok
  end

  def get_zone_query_stats(zone_id) when is_integer(zone_id) do
    flush_query_stats_buffer()

    today = Date.utc_today()
    week_ago = Date.add(today, -6)

    # Single scan of the zone's rollup rows with conditional aggregates instead of
    # four separate SUM queries over the same (zone_id, query_date) index.
    stats =
      from(qs in QueryStat,
        where: qs.zone_id == ^zone_id,
        select: %{
          total_queries: fragment("COALESCE(SUM(?), 0)", qs.query_count),
          queries_today:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? >= ?), 0)",
              qs.query_count,
              qs.query_date,
              ^today
            ),
          queries_this_week:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? >= ?), 0)",
              qs.query_count,
              qs.query_date,
              ^week_ago
            ),
          nxdomain_queries:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? = ?), 0)",
              qs.query_count,
              qs.rcode,
              "NXDOMAIN"
            )
        }
      )
      |> Repo.one()

    stats || empty_query_stats()
  end

  def get_zone_query_stats(_), do: empty_query_stats()

  def get_zone_daily_query_counts(zone_id, days \\ 30)

  def get_zone_daily_query_counts(zone_id, days) when is_integer(zone_id) and days > 0 do
    flush_query_stats_buffer()

    start_date = Date.add(Date.utc_today(), -days + 1)
    end_date = Date.utc_today()

    actual_counts =
      from(qs in QueryStat,
        where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
        group_by: qs.query_date,
        select: %{date: qs.query_date, count: sum(qs.query_count)}
      )
      |> Repo.all()
      |> Map.new(fn %{date: date, count: count} -> {date, count || 0} end)

    Date.range(start_date, end_date)
    |> Enum.map(fn date -> %{date: date, count: Map.get(actual_counts, date, 0)} end)
  end

  def get_zone_daily_query_counts(_, _), do: []

  def get_zone_hourly_query_counts(zone_id, hours \\ 24)

  def get_zone_hourly_query_counts(zone_id, hours) when is_integer(zone_id) and hours > 0 do
    flush_query_stats_buffer()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> truncate_to_hour()
    start_hour = DateTime.add(now, -(hours - 1), :hour)

    actual_counts =
      from(qs in QueryStat,
        where: qs.zone_id == ^zone_id and qs.query_hour >= ^start_hour,
        group_by: qs.query_hour,
        select: %{hour: qs.query_hour, count: sum(qs.query_count)}
      )
      |> Repo.all()
      |> Map.new(fn %{hour: hour, count: count} -> {hour, count || 0} end)

    0..(hours - 1)
    |> Enum.map(fn offset -> DateTime.add(start_hour, offset, :hour) end)
    |> Enum.map(fn hour -> %{hour: hour, count: Map.get(actual_counts, hour, 0)} end)
  end

  def get_zone_hourly_query_counts(_, _), do: []

  def get_zone_query_type_breakdown(zone_id, limit \\ 10)

  def get_zone_query_type_breakdown(zone_id, limit) when is_integer(zone_id) do
    flush_query_stats_buffer()
    start_date = Date.add(Date.utc_today(), -29)

    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
      group_by: qs.qtype,
      select: %{qtype: qs.qtype, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.qtype],
      limit: ^limit
    )
    |> Repo.all()
  end

  def get_zone_query_type_breakdown(_, _), do: []

  def get_zone_top_names(zone_id, limit \\ 10)

  def get_zone_top_names(zone_id, limit) when is_integer(zone_id) do
    flush_query_stats_buffer()
    start_date = Date.add(Date.utc_today(), -29)

    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
      group_by: qs.qname,
      select: %{qname: qs.qname, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.qname],
      limit: ^limit
    )
    |> Repo.all()
  end

  def get_zone_top_names(_, _), do: []

  def get_zone_top_nxdomain_names(zone_id, limit \\ 10)

  def get_zone_top_nxdomain_names(zone_id, limit) when is_integer(zone_id) do
    flush_query_stats_buffer()
    start_date = Date.add(Date.utc_today(), -29)

    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.rcode == "NXDOMAIN" and qs.query_date >= ^start_date,
      group_by: qs.qname,
      select: %{qname: qs.qname, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.qname],
      limit: ^limit
    )
    |> Repo.all()
  end

  def get_zone_top_nxdomain_names(_, _), do: []

  def get_zone_rcode_breakdown(zone_id) when is_integer(zone_id) do
    flush_query_stats_buffer()
    start_date = Date.add(Date.utc_today(), -29)

    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
      group_by: qs.rcode,
      select: %{rcode: qs.rcode, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.rcode]
    )
    |> Repo.all()
  end

  def get_zone_rcode_breakdown(_), do: []

  def get_zone_transport_breakdown(zone_id) when is_integer(zone_id) do
    flush_query_stats_buffer()
    start_date = Date.add(Date.utc_today(), -29)

    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
      group_by: qs.transport,
      select: %{transport: qs.transport, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.transport]
    )
    |> Repo.all()
  end

  def get_zone_transport_breakdown(_), do: []

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

  def recursive_max_upstream_queries do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_max_upstream_queries, 32)
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
      "100.64.0.0/10",
      "::1/128",
      "fc00::/7"
    ])
  end

  def public_hostname?(hostname) when is_binary(hostname) do
    normalized =
      hostname
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    normalized != "" and
      String.contains?(normalized, ".") and
      valid_hostname_labels?(normalized) and
      not String.contains?(normalized, ["/", "@", " "]) and
      not ip_literal?(normalized) and
      not restricted_hostname?(normalized)
  end

  def public_hostname?(_), do: false

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
      nil -> "admin.example.com"
      domain -> "admin.#{domain}"
    end
  end

  defp primary_domain do
    Application.get_env(:elektrine, :primary_domain)
  end

  defp nil_or_blank?(nil), do: true
  defp nil_or_blank?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp nil_or_blank?(_), do: false

  defp restricted_hostname?(hostname) do
    hostname in ["localhost", "invalid", "local", "localdomain"] or
      String.ends_with?(hostname, ".localhost") or
      String.ends_with?(hostname, ".local") or
      String.ends_with?(hostname, ".internal") or
      String.ends_with?(hostname, ".home.arpa") or
      String.ends_with?(hostname, ".localdomain") or
      String.ends_with?(hostname, ".test") or
      String.ends_with?(hostname, ".invalid") or
      String.ends_with?(hostname, ".example") or
      String.ends_with?(hostname, ".example.com") or
      String.ends_with?(hostname, ".example.net") or
      String.ends_with?(hostname, ".example.org") or
      String.ends_with?(hostname, ".in-addr.arpa") or
      String.ends_with?(hostname, ".ip6.arpa")
  end

  defp valid_hostname_labels?(hostname) do
    hostname
    |> String.split(".", trim: true)
    |> Enum.all?(fn label ->
      label != "" and
        String.length(label) <= 63 and
        Regex.match?(~r/^[a-z0-9-]+$/, label) and
        not String.starts_with?(label, "-") and
        not String.ends_with?(label, "-")
    end)
  end

  defp ip_literal?(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _ip} -> true
      {:error, _reason} -> false
    end
  end

  defp verify_nameservers(%Zone{domain: domain} = zone) do
    if public_hostname?(domain) do
      expected = zone |> assigned_nameservers() |> Enum.map(&normalize_hostname/1) |> Enum.sort()

      case delegated_nameserver_data(domain) do
        {:ok, %{nameservers: resolved, endpoints: endpoints}} ->
          resolved = Enum.sort(resolved)

          if expected == resolved do
            verify_authoritative_nameservers(domain, endpoints)
          else
            {:error, delegation_mismatch_message(expected, resolved)}
          end

        {:error, reason} ->
          {:error, "NS lookup failed for #{domain}: #{reason}"}
      end
    else
      {:error, "Zone verification only supports public DNS domains"}
    end
  rescue
    error -> {:error, "NS lookup failed for #{domain}: #{inspect(error)}"}
  end

  defp verify_authoritative_nameservers(_domain, endpoints) do
    case endpoints do
      [] ->
        {:error,
         "Delegation matches the configured nameservers, but no usable A/AAAA records were found for them."}

      _endpoints ->
        :ok
    end
  end

  defp delegated_nameserver_data(domain) do
    with {:ok, tld_endpoints} <- tld_nameserver_endpoints(domain),
         {:ok, response} <- query_nameserver_group(domain, :ns, tld_endpoints),
         {:ok, nameservers} <- extract_delegated_nameservers(response, domain) do
      endpoints = extract_nameserver_endpoints(response, nameservers)

      {:ok,
       %{
         nameservers: nameservers,
         endpoints:
           case endpoints do
             [] -> fallback_nameserver_endpoints(nameservers)
             values -> values
           end
       }}
    end
  end

  defp tld_nameserver_endpoints(domain) do
    case tld_domain(domain) do
      nil ->
        {:error, "could not derive the parent zone"}

      tld ->
        with {:ok, response} <- query_nameserver_group(tld, :ns, recursive_root_hints()),
             {:ok, nameservers} <- extract_delegated_nameservers(response, tld) do
          endpoints = extract_nameserver_endpoints(response, nameservers)

          if endpoints == [] do
            {:error, "no usable parent nameserver glue was returned for #{tld}"}
          else
            {:ok, endpoints}
          end
        end
    end
  end

  defp query_nameserver_group(qname, qtype, endpoints) do
    query = %{id: 1, rd: 0, qname: qname, qtype: qtype, udp_size: max_udp_payload()}
    packet = Packet.encode_query(query)

    endpoints
    |> Enum.reduce_while([], fn {ip, port}, errors ->
      case recursive_transport().exchange_udp(ip, port, packet, recursive_timeout()) do
        {:ok, response} ->
          {:halt, {:ok, response}}

        {:error, reason} ->
          {:cont, [{ip, port, {:error, format_dns_exchange_error(reason)}} | errors]}
      end
    end)
    |> case do
      {:ok, response} ->
        {:ok, response}

      errors when is_list(errors) ->
        {:error, format_endpoint_attempt_errors(Enum.reverse(errors))}
    end
  end

  defp extract_delegated_nameservers(response, domain) do
    normalized_domain = normalize_hostname(domain)

    case :inet_dns.decode(response) do
      {:ok, {:dns_rec, _header, _qd, answers, authority, _additional}} ->
        nameservers =
          (answers ++ authority)
          |> Enum.filter(fn answer ->
            elem(answer, 2) in [2, :ns] and
              normalize_hostname(elem(answer, 1)) == normalized_domain
          end)
          |> Enum.map(fn answer -> normalize_hostname(elem(answer, 6)) end)
          |> Enum.uniq()

        {:ok, nameservers}

      _ ->
        {:error, "received an invalid DNS response"}
    end
  end

  defp extract_nameserver_endpoints(response, nameservers) do
    nameserver_set = MapSet.new(nameservers)

    case :inet_dns.decode(response) do
      {:ok, {:dns_rec, _header, _qd, _answers, _authority, additional}} ->
        additional
        |> Enum.filter(fn answer ->
          normalize_hostname(elem(answer, 1)) in nameserver_set and
            elem(answer, 2) in [1, 28, :a, :aaaa]
        end)
        |> Enum.map(fn answer -> {parse_rr_ip(answer), 53} end)
        |> Enum.reject(fn {ip, _port} -> is_nil(ip) end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp fallback_nameserver_endpoints(nameservers) do
    nameservers
    |> Enum.flat_map(fn nameserver ->
      lookup_dns_values(nameserver, :a, timeout: 5_000) ++
        lookup_dns_values(nameserver, :aaaa, timeout: 5_000)
    end)
    |> Enum.map(&parse_ip/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, 53})
    |> Enum.uniq()
  end

  defp format_dns_exchange_error(:timeout), do: "query timed out"

  defp format_dns_exchange_error(:unexpected_upstream),
    do: "received a reply from an unexpected upstream"

  defp format_dns_exchange_error(:eafnosupport),
    do: "address family not supported by this runtime"

  defp format_dns_exchange_error(reason), do: to_string(reason)

  defp format_endpoint_attempt_errors([]), do: "query timed out"

  defp format_endpoint_attempt_errors(attempts) do
    reasons =
      attempts
      |> Enum.map(fn {_ip, _port, {:error, reason}} -> reason end)
      |> Enum.uniq()

    case reasons do
      [reason] ->
        reason

      _ ->
        Enum.map_join(attempts, "; ", fn {ip, port, {:error, reason}} ->
          "#{format_dns_endpoint(ip, port)} #{reason}"
        end)
    end
  end

  defp format_dns_endpoint(ip, port) do
    host =
      ip
      |> :inet.ntoa()
      |> to_string()

    host =
      if tuple_size(ip) == 8 do
        "[#{host}]"
      else
        host
      end

    if port == 53, do: host <> ":", else: "#{host}:#{port}:"
  end

  defp delegation_mismatch_message(expected, resolved) do
    "Delegation mismatch for the configured nameservers. Expected: #{format_nameserver_list(expected)}. Observed: #{format_nameserver_list(resolved)}."
  end

  defp format_nameserver_list([]), do: "none"
  defp format_nameserver_list(nameservers), do: Enum.join(nameservers, ", ")

  defp lookup_dns_values(domain, type, opts) when is_binary(domain) do
    domain
    |> String.to_charlist()
    |> dns_resolver().lookup(:in, type, opts)
    |> Enum.map(&normalize_lookup_value(type, &1))
    |> Enum.reject(&nil_or_blank?/1)
    |> Enum.uniq()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp normalize_lookup_value(:ns, value), do: normalize_hostname(value)
  defp normalize_lookup_value(:cname, value), do: normalize_hostname(value)
  defp normalize_lookup_value(:a, {a, b, c, d}), do: Enum.join([a, b, c, d], ".")

  defp normalize_lookup_value(:aaaa, tuple) when is_tuple(tuple) and tuple_size(tuple) == 8 do
    tuple
    |> Tuple.to_list()
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
  end

  defp normalize_lookup_value(:mx, {priority, host}),
    do: "#{priority} #{normalize_hostname(host)}"

  defp normalize_lookup_value(_, value) when is_binary(value), do: String.trim(value)

  defp normalize_lookup_value(_, value) when is_list(value),
    do: value |> List.to_string() |> String.trim()

  defp normalize_lookup_value(_, value), do: to_string(value)

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp parse_ip(_value), do: nil

  defp parse_rr_ip(answer), do: answer |> elem(6)

  defp assign_nameserver_set_on_create(%Zone{} = zone) do
    case nameserver_sets() do
      [] ->
        zone

      sets ->
        nameserver_set = safe_nameserver_set(zone, sets)

        zone
        |> Zone.changeset(%{nameserver_set: nameserver_set})
        |> Repo.update!()
    end
  end

  defp safe_nameserver_set(%Zone{} = zone, sets) do
    initial = deterministic_nameserver_set(zone, length(sets))
    observed = observed_delegation_for_assignment(zone.domain)

    if nameserver_set_matches_observed?(Enum.at(sets, initial), observed) do
      next_safe_nameserver_set(initial, sets, observed)
    else
      initial
    end
  end

  defp next_safe_nameserver_set(initial, sets, observed) do
    set_count = length(sets)

    1..set_count
    |> Enum.map(&rem(initial + &1, set_count))
    |> Enum.find(fn index ->
      not nameserver_set_matches_observed?(Enum.at(sets, index), observed)
    end)
    |> case do
      nil -> initial
      index -> index
    end
  end

  defp nameserver_set_matches_observed?(_set, []), do: false

  defp nameserver_set_matches_observed?(set, observed) do
    set |> Enum.map(&normalize_hostname/1) |> Enum.sort() == observed
  end

  defp observed_delegation_for_assignment(domain) do
    domain
    |> lookup_dns_values(:ns, timeout: 1_500)
    |> Enum.map(&normalize_hostname/1)
    |> Enum.sort()
  end

  defp deterministic_nameserver_set(%Zone{} = zone, set_count) when set_count > 0 do
    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        nameserver_assignment_secret(),
        nameserver_assignment_payload(zone)
      )

    <<value::unsigned-big-integer-size(32), _::binary>> = digest
    rem(value, set_count)
  end

  defp zone_nameserver_set(%Zone{nameserver_set: set}, set_count)
       when is_integer(set) and set >= 0 and set_count > 0 do
    rem(set, set_count)
  end

  defp zone_nameserver_set(%Zone{} = zone, set_count) when set_count > 0 do
    deterministic_nameserver_set(zone, set_count)
  end

  defp nameserver_assignment_payload(%Zone{} = zone) do
    "#{zone.id}:#{zone.user_id}:#{normalize_hostname(zone.domain)}"
  end

  defp nameserver_assignment_secret do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:nameserver_assignment_secret)
    |> case do
      secret when is_binary(secret) and secret != "" ->
        secret

      _ ->
        endpoint_config = Application.get_env(:elektrine, ElektrineWeb.Endpoint, [])

        endpoint_config[:secret_key_base] ||
          Elektrine.RuntimeSecrets.secret_key_base() ||
          "elektrine-dns-development-nameserver-assignment"
    end
  end

  defp assigned_nameserver_base(host) do
    base_nameservers = nameservers()

    nameserver_sets()
    |> Enum.find_value(fn set ->
      set
      |> Enum.find_index(&(normalize_hostname(&1) == host))
      |> case do
        nil -> nil
        index -> Enum.at(base_nameservers, rem(index, max(length(base_nameservers), 1)))
      end
    end)
    |> case do
      nil -> legacy_assigned_nameserver_base(host)
      nameserver -> nameserver
    end
  end

  defp legacy_assigned_nameserver_base(host) do
    Enum.find(nameservers(), fn nameserver ->
      nameserver = normalize_hostname(nameserver)
      String.starts_with?(host, "z") and String.ends_with?(host, "." <> nameserver)
    end)
  end

  defp nameserver_sets do
    configured =
      Application.get_env(:elektrine, :dns, [])
      |> Keyword.get(:nameserver_sets, [])
      |> normalize_nameserver_sets()

    case configured do
      [] -> default_nameserver_sets()
      sets -> sets
    end
  end

  defp normalize_nameserver_sets(sets) when is_list(sets) do
    sets
    |> Enum.map(fn set ->
      set
      |> List.wrap()
      |> Enum.map(&normalize_hostname/1)
      |> Enum.reject(&nil_or_blank?/1)
    end)
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp normalize_nameserver_sets(_), do: []

  defp default_nameserver_sets do
    base_nameservers =
      nameservers()
      |> Enum.map(&normalize_hostname/1)
      |> Enum.reject(&nil_or_blank?/1)

    case base_nameservers do
      [] ->
        []

      [_single] ->
        []

      base_nameservers ->
        Enum.map(@nameserver_label_pairs, fn labels ->
          labels
          |> Enum.with_index()
          |> Enum.map(fn {label, index} ->
            "#{label}.#{Enum.at(base_nameservers, rem(index, length(base_nameservers)))}"
          end)
        end)
    end
  end

  defp maybe_add_nameserver_address_records(
         records,
         host,
         nameserver,
         lookup_type,
         record_type,
         qtype
       ) do
    if qtype in [:any, lookup_type] do
      nameserver
      |> lookup_dns_values(lookup_type, timeout: 5_000)
      |> Enum.map(fn address ->
        %{host: host, type: record_type, content: address, ttl: default_ttl()}
      end)
      |> Kernel.++(records)
    else
      records
    end
  end

  defp normalize_query_type(type) when type in [:a, :aaaa, :any], do: type
  defp normalize_query_type("A"), do: :a
  defp normalize_query_type("AAAA"), do: :aaaa
  defp normalize_query_type("ANY"), do: :any
  defp normalize_query_type(type), do: type

  defp tld_domain(domain) do
    domain
    |> normalize_hostname()
    |> String.split(".", trim: true)
    |> List.last()
  end

  defp delegated_to_elektrine?(observed_nameservers) do
    observed = observed_nameservers |> Enum.map(&normalize_hostname/1) |> Enum.sort()
    base_nameservers = nameservers() |> Enum.map(&normalize_hostname/1) |> Enum.sort()

    observed == base_nameservers or
      Enum.any?(nameserver_sets(), fn set ->
        set |> Enum.map(&normalize_hostname/1) |> Enum.sort() == observed
      end)
  end

  defp provider_hint([]), do: nil

  defp provider_hint(nameservers) do
    joined = Enum.join(nameservers, " ")

    cond do
      String.contains?(joined, "awsdns-") -> "Route53"
      String.contains?(joined, "digitalocean.com") -> "DigitalOcean"
      String.contains?(joined, "domaincontrol.com") -> "GoDaddy"
      String.contains?(joined, "squarespacedns.com") -> "Squarespace"
      String.contains?(joined, "namecheap.com") -> "Namecheap"
      String.contains?(joined, "google.com") -> "Google Cloud DNS"
      true -> List.first(nameservers)
    end
  end

  defp scan_record_entry(_host, _type, []), do: nil
  defp scan_record_entry(host, type, values), do: %{host: host, type: type, values: values}

  defp normalize_hostname(value) when is_binary(value),
    do: value |> String.trim() |> String.trim_trailing(".") |> String.downcase()

  defp normalize_hostname(value) when is_list(value),
    do: value |> List.to_string() |> normalize_hostname()

  defp normalize_hostname(value), do: value |> to_string() |> normalize_hostname()

  defp normalize_service(service) when is_binary(service), do: String.downcase(service)
  defp normalize_service(service), do: to_string(service) |> String.downcase()

  defp empty_query_stats do
    %{total_queries: 0, queries_today: 0, queries_this_week: 0, nxdomain_queries: 0}
  end

  defp normalize_dns_metric_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_dns_metric_value(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_dns_metric_value(value), do: value |> to_string() |> String.upcase()

  defp truncate_to_hour(%DateTime{} = date_time) do
    %{date_time | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp normalize_dns_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_dns_name(value), do: value |> to_string() |> normalize_dns_name()

  defp normalize_dns_metric_name(qname, zone_domain, rcode) do
    qname = normalize_dns_name(qname)
    zone_domain = normalize_dns_name(zone_domain)
    qname_labels = String.split(qname, ".", trim: true)
    zone_labels = String.split(zone_domain, ".", trim: true)
    max_labels = length(zone_labels) + 2

    cond do
      preserve_metric_qname?(qname_labels) ->
        qname

      rcode == "NXDOMAIN" and String.ends_with?(qname, "." <> zone_domain) and
          length(qname_labels) > max_labels ->
        suffix = qname_labels |> Enum.take(-max_labels) |> Enum.join(".")
        "*." <> suffix

      rcode == "NXDOMAIN" and String.ends_with?(qname, "." <> zone_domain) ->
        "*." <> zone_domain

      String.ends_with?(qname, "." <> zone_domain) and length(qname_labels) > max_labels ->
        suffix = qname_labels |> Enum.take(-max_labels) |> Enum.join(".")
        "*." <> suffix

      true ->
        qname
    end
  end

  defp preserve_metric_qname?([label | _]), do: label in ["_acme-challenge", "_atproto"]
  defp preserve_metric_qname?(_), do: false

  defp refresh_authority_cache_after_write(result, opts \\ [])

  defp refresh_authority_cache_after_write({:ok, result}, opts) do
    result =
      if Keyword.get(opts, :touch_zone, false), do: touch_authority_zone(result), else: result

    refresh_authority_cache()
    {:ok, result}
  end

  defp refresh_authority_cache_after_write(result, _opts), do: result

  defp maybe_ensure_profile_wildcards_after_zone_write({:ok, %Zone{} = zone} = result) do
    profile_base_domains =
      Domains.profile_base_domains()
      |> Enum.map(&normalize_zone_host/1)

    if normalize_zone_host(zone.domain) in profile_base_domains do
      _ = ensure_profile_subdomain_wildcards()
    end

    result
  end

  defp maybe_ensure_profile_wildcards_after_zone_write(result), do: result

  defp touch_authority_zone(%Record{zone_id: zone_id} = record) do
    _ = touch_zone_publication(zone_id)
    record
  end

  defp touch_authority_zone(%Zone{id: zone_id} = zone) do
    case touch_zone_publication(zone_id) do
      %Zone{} = updated -> Repo.preload(updated, [:records, :service_configs])
      _ -> zone
    end
  end

  defp touch_authority_zone(%ZoneServiceConfig{zone_id: zone_id} = config) do
    _ = touch_zone_publication(zone_id)
    config
  end

  defp touch_authority_zone(result), do: result

  defp touch_zone_publication(zone_id) when is_integer(zone_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Zone
    |> where([z], z.id == ^zone_id)
    |> select([z], z)
    |> Repo.update_all(inc: [serial: 1], set: [last_published_at: now])
    |> case do
      {1, [zone]} -> zone
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp touch_zone_publication(_), do: nil

  defp refresh_authority_cache(opts \\ []) do
    case Process.whereis(ZoneCache) do
      nil ->
        :ok

      _pid ->
        if Keyword.get(opts, :async, false) do
          ZoneCache.refresh_async()
        else
          case ZoneCache.refresh(caller: self()) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("DNS zone cache refresh skipped: #{inspect(reason)}")
          end
        end
    end
  end

  defp ensure_builtin_user_zone(%{id: user_id}, domain) when is_integer(user_id) do
    zone =
      Zone
      |> where([z], z.user_id == ^user_id and fragment("lower(?)", z.domain) == ^domain)
      |> preload([:records, :service_configs])
      |> Repo.one()

    case zone do
      %Zone{} = existing ->
        case ensure_builtin_user_zone_records(existing, refresh_cache?: false) do
          {:ok, zone} ->
            refresh_authority_cache(async: true)
            {:ok, zone}

          other ->
            other
        end

      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          zone =
            %Zone{}
            |> Zone.changeset(%{
              domain: domain,
              user_id: user_id,
              status: "verified",
              kind: "native",
              default_ttl: default_ttl(),
              force_https: false,
              soa_mname: List.first(nameservers()),
              soa_rname: soa_rname(),
              soa_minimum: default_ttl(),
              verified_at: now,
              last_checked_at: now
            })
            |> Repo.insert!()

          zone
          |> Repo.preload([:records, :service_configs])
          |> ensure_builtin_user_zone_records!()
        end)
        |> case do
          {:ok, zone} ->
            refresh_authority_cache(async: true)
            {:ok, zone}

          other ->
            other
        end
    end
  end

  defp ensure_builtin_user_zone_records(%Zone{} = zone, opts \\ []) do
    zone = Repo.preload(zone, [:records, :service_configs], force: true)

    if builtin_user_zone_records_current?(zone) do
      {:ok, zone}
    else
      Repo.transaction(fn ->
        zone
        |> Repo.preload([:records, :service_configs], force: true)
        |> ensure_builtin_user_zone_records!()
      end)
      |> case do
        {:ok, zone} ->
          if Keyword.get(opts, :refresh_cache?, true) do
            refresh_authority_cache()
          end

          {:ok, zone}

        other ->
          other
      end
    end
  end

  defp ensure_builtin_user_zone_records!(%Zone{} = zone) do
    zone = reconcile_builtin_zone_apex_record(zone)

    if zone.status != "verified" or is_nil(zone.verified_at) do
      zone
      |> Zone.changeset(%{
        status: "verified",
        verified_at: zone.verified_at || DateTime.utc_now() |> DateTime.truncate(:second),
        last_checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_error: nil
      })
      |> Repo.update!()
      |> Repo.preload([:records, :service_configs])
    else
      zone
    end
  end

  defp reconcile_builtin_zone_apex_record(%Zone{} = zone) do
    if builtin_user_zone_hosted_by_platform?(zone) do
      maybe_upsert_builtin_zone_apex_record(zone)
    else
      delete_builtin_zone_apex_record(zone)
    end
  end

  defp maybe_upsert_builtin_zone_apex_record(%Zone{} = zone) do
    attrs = %{
      zone_id: zone.id,
      name: "@",
      type: "ALIAS",
      ttl: default_ttl(),
      content: Domains.profile_custom_domain_routing_target(),
      source: "system",
      service: @builtin_user_zone_managed_service,
      managed: true,
      managed_key: @builtin_user_zone_apex_managed_key,
      required: true,
      metadata: %{"label" => "Built-in profile routing"}
    }

    case Repo.get_by(Record, zone_id: zone.id, managed_key: @builtin_user_zone_apex_managed_key) do
      %Record{} = record ->
        if builtin_zone_apex_record_matches?(record, attrs) do
          :ok
        else
          record
          |> Record.changeset(attrs)
          |> Repo.insert_or_update!()
        end

      nil ->
        %Record{}
        |> Record.changeset(attrs)
        |> Repo.insert!()
    end

    Repo.preload(zone, [:records, :service_configs], force: true)
  end

  defp delete_builtin_zone_apex_record(%Zone{} = zone) do
    case Repo.get_by(Record, zone_id: zone.id, managed_key: @builtin_user_zone_apex_managed_key) do
      %Record{} = record -> Repo.delete!(record)
      nil -> :ok
    end

    Repo.preload(zone, [:records, :service_configs], force: true)
  end

  defp builtin_user_zone_records_current?(%Zone{} = zone) do
    zone.status == "verified" and not is_nil(zone.verified_at) and
      builtin_user_zone_apex_state_current?(zone)
  end

  defp builtin_user_zone_apex_state_current?(%Zone{} = zone) do
    has_managed_apex? = Enum.any?(zone.records, &builtin_zone_apex_record_matches?(&1))

    if builtin_user_zone_hosted_by_platform?(zone),
      do: has_managed_apex?,
      else: not has_managed_apex?
  end

  defp builtin_zone_apex_record_matches?(%Record{} = record) do
    builtin_zone_apex_record_matches?(record, %{
      name: "@",
      type: "ALIAS",
      content: Domains.profile_custom_domain_routing_target(),
      source: "system",
      service: @builtin_user_zone_managed_service,
      managed: true,
      managed_key: @builtin_user_zone_apex_managed_key,
      required: true
    })
  end

  defp builtin_zone_apex_record_matches?(%Record{} = record, attrs) do
    record.name == attrs.name and record.type == attrs.type and record.content == attrs.content and
      record.source == attrs.source and record.service == attrs.service and
      record.managed == attrs.managed and record.managed_key == attrs.managed_key and
      record.required == attrs.required
  end

  defp create_zone_attrs(attrs, user_id) do
    attrs
    |> public_zone_attrs()
    |> Map.put("user_id", user_id)
  end

  defp public_zone_attrs(attrs) do
    Map.take(attrs, [
      "domain",
      "kind",
      "default_ttl",
      "force_https",
      "soa_mname",
      "soa_rname",
      "soa_refresh",
      "soa_retry",
      "soa_expire",
      "soa_minimum"
    ])
  end

  defp update_zone_verification(%Zone{} = zone, attrs) when is_map(attrs) do
    zone
    |> Zone.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, zone} -> {:ok, Repo.preload(zone, [:records, :service_configs])}
      error -> error
    end
    |> refresh_authority_cache_after_write()
  end

  defp public_record_attrs(attrs) do
    Map.drop(attrs, ["zone_id", :zone_id])
  end

  defp normalize_record_attrs(attrs, nil), do: attrs

  defp normalize_record_attrs(attrs, zone_domain) when is_map(attrs) do
    case Map.fetch(attrs, "name") do
      {:ok, name} -> Map.put(attrs, "name", normalize_record_name(name, zone_domain))
      :error -> attrs
    end
  end

  defp normalize_record_name(name, zone_domain) when is_binary(name) do
    normalized_name =
      name
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()
      |> case do
        "\\@" -> "@"
        value -> value
      end

    normalized_zone =
      zone_domain |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    cond do
      normalized_name in ["", "@"] ->
        "@"

      normalized_name == normalized_zone ->
        "@"

      String.ends_with?(normalized_name, "." <> normalized_zone) ->
        normalized_name
        |> String.trim_trailing("." <> normalized_zone)
        |> case do
          "" -> "@"
          relative -> relative
        end

      true ->
        normalized_name
    end
  end

  defp normalize_record_name(name, _zone_domain), do: name

  defp validate_zone_record_write(%Zone{} = zone, attrs) when is_map(attrs) do
    with :ok <- validate_cname_exclusivity(zone, attrs) do
      if builtin_user_zone?(zone) and builtin_user_zone_hosted_by_platform?(zone) do
        validate_builtin_zone_record_write(zone, attrs)
      else
        :ok
      end
    end
  end

  defp validate_zone_record_write(_, _), do: :ok

  defp validate_cname_exclusivity(zone, attrs) do
    name = Map.get(attrs, "name", "@") |> normalize_record_name(zone.domain)
    type = attrs |> Map.get("type") |> normalize_record_type()

    records =
      Record
      |> where([r], r.zone_id == ^zone.id and r.name == ^name)
      |> Repo.all()

    cond do
      type == "CNAME" and Enum.any?(records, &(&1.type != "CNAME")) ->
        {:error,
         add_error(change(%Record{}), :type, "cannot coexist with other records at the same name")}

      type != "CNAME" and Enum.any?(records, &(&1.type == "CNAME")) ->
        {:error, add_error(change(%Record{}), :name, "already has a CNAME record")}

      true ->
        :ok
    end
  end

  defp validate_builtin_zone_record_write(zone, attrs) do
    name = Map.get(attrs, "name", "@") |> normalize_record_name(zone.domain)
    type = attrs |> Map.get("type") |> normalize_record_type()

    cond do
      type in @builtin_user_zone_forbidden_types ->
        {:error,
         add_error(change(%Record{}), :type, "is reserved on built-in profile subdomains")}

      name == "@" and type not in @builtin_user_zone_allowed_apex_types ->
        {:error,
         add_error(
           change(%Record{}),
           :name,
           "the apex host is reserved for Elektrine profile routing; only TXT and CAA are allowed there"
         )}

      true ->
        :ok
    end
  end

  defp validate_record_mutation(%Record{} = record, action) do
    if action == :delete and protected_builtin_zone_record?(record) do
      {:error, add_error(change(record), :name, "is managed by Elektrine and cannot be deleted")}
    else
      :ok
    end
  end

  defp protected_builtin_zone_record?(%Record{
         managed: true,
         required: true,
         managed_key: managed_key
       })
       when managed_key == @builtin_user_zone_apex_managed_key,
       do: true

  defp protected_builtin_zone_record?(_), do: false

  defp record_write_attrs(%Record{} = record) do
    %{
      "name" => record.name,
      "type" => record.type,
      "ttl" => record.ttl,
      "content" => record.content,
      "priority" => record.priority,
      "weight" => record.weight,
      "port" => record.port,
      "flags" => record.flags,
      "tag" => record.tag,
      "protocol" => record.protocol,
      "algorithm" => record.algorithm,
      "key_tag" => record.key_tag,
      "digest_type" => record.digest_type,
      "usage" => record.usage,
      "selector" => record.selector,
      "matching_type" => record.matching_type
    }
  end

  defp proxied_zone_for_host(host) do
    host
    |> candidate_zone_domains()
    |> Enum.find_value(fn domain ->
      Zone
      |> where([z], z.status == "verified" and fragment("lower(?)", z.domain) == ^domain)
      |> preload(:records)
      |> Repo.one()
    end)
  end

  defp proxied_record_for_host(%Zone{} = zone, host) do
    zone.records
    |> Enum.filter(&(Record.proxied?(&1) and record_fqdn(zone, &1) == host))
    |> Enum.sort_by(&proxy_record_priority/1)
    |> List.first()
  end

  defp proxied_origin(%Zone{} = zone, %Record{} = record, host) do
    scheme = Record.proxy_origin_scheme(record)
    port = Record.proxy_origin_port(record)

    origin_host =
      record.content |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    host_header = Record.proxy_origin_host_header(record) || host

    %{
      zone_id: zone.id,
      zone_domain: zone.domain,
      record_id: record.id,
      host: host,
      origin_scheme: scheme,
      origin_host: origin_host,
      origin_port: port,
      origin_url: origin_url(scheme, origin_host, port),
      origin_host_header: host_header,
      atomine_gate: Record.proxy_atomine_gate?(record)
    }
  end

  defp origin_url(scheme, host, port) do
    default_port = if scheme == "http", do: 80, else: 443
    port_suffix = if port == default_port, do: "", else: ":#{port}"
    scheme <> "://" <> host <> port_suffix
  end

  defp proxy_record_priority(%Record{type: "A"}), do: 0
  defp proxy_record_priority(%Record{type: "AAAA"}), do: 1
  defp proxy_record_priority(%Record{type: "CNAME"}), do: 2
  defp proxy_record_priority(%Record{type: "ALIAS"}), do: 3
  defp proxy_record_priority(_), do: 4

  defp record_fqdn(%Zone{} = zone, %Record{name: name}) when is_binary(name) do
    zone_domain = normalize_proxy_host(zone.domain)
    normalized_name = normalize_proxy_host(name)

    cond do
      normalized_name in ["", "@"] -> zone_domain
      normalized_name == zone_domain -> zone_domain
      String.ends_with?(normalized_name, "." <> zone_domain) -> normalized_name
      true -> normalized_name <> "." <> zone_domain
    end
  end

  defp candidate_zone_domains(host) do
    host
    |> String.split(".", trim: true)
    |> case do
      [] -> []
      labels -> Enum.map(0..(length(labels) - 1), &(labels |> Enum.drop(&1) |> Enum.join(".")))
    end
  end

  defp normalize_proxy_host(host) do
    host
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_record_type(nil), do: nil

  defp normalize_record_type(type) when is_binary(type),
    do: type |> String.trim() |> String.upcase()

  defp normalize_record_type(type), do: type |> to_string() |> normalize_record_type()

  defp sort_user_zones(zones, nil), do: zones

  defp sort_user_zones(zones, builtin_domain) do
    Enum.sort_by(zones, fn zone ->
      {zone.domain != builtin_domain, zone.domain}
    end)
  end

  defp validate_platform_handoff(user) do
    if builtin_user_zone_hosted_by_platform?(user) do
      case get_zone_by_domain(builtin_user_zone_domain(user)) do
        %Zone{} = zone ->
          zone = Repo.preload(zone, :records, force: true)

          case Enum.reject(zone.records, &apex_record_allowed_when_platform_hosted?/1) do
            [] ->
              :ok

            conflicts ->
              names = Enum.map_join(conflicts, ", ", &record_conflict_label/1)

              {:error,
               add_error(
                 change(user),
                 :built_in_subdomain_mode,
                 "cannot switch back to platform hosting until apex records are removed: #{names}"
               )}
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp apex_record_allowed_when_platform_hosted?(%Record{} = record) do
    record.name != "@" or record.managed_key == @builtin_user_zone_apex_managed_key or
      record.type in @builtin_user_zone_allowed_apex_types
  end

  defp record_conflict_label(%Record{} = record), do: "#{record.name} #{record.type}"

  defp user_schema?(%{__struct__: @user_schema, id: id}) when is_integer(id), do: true

  defp user_schema?(_), do: false

  defp zone_domain(zone_id) when is_integer(zone_id) do
    case Repo.get(Zone, zone_id) do
      %Zone{domain: domain} -> domain
      _ -> nil
    end
  end

  defp zone_domain(_), do: nil
end
