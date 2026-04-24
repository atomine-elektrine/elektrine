defmodule Elektrine.DNS do
  @moduledoc """
  Core context for Elektrine's managed DNS service.
  """

  import Ecto.Changeset, only: [add_error: 3, change: 1]
  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.DNS.ManagedRecords
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
  @builtin_user_zone_forbidden_types ~w(ALIAS DNSKEY DS NS TLSA)
  @builtin_user_zone_allowed_apex_types ~w(CAA TXT)
  @builtin_user_zone_modes User.built_in_subdomain_modes()

  def list_user_zones(%User{} = user) do
    _ = ensure_builtin_user_zone(user)

    user.id
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

  def ensure_builtin_user_zone(%User{} = user) do
    case builtin_user_zone_domain(user) do
      nil -> {:error, :invalid_user}
      domain -> ensure_builtin_user_zone(user, domain)
    end
  end

  def ensure_builtin_user_zone(_), do: {:error, :invalid_user}

  def builtin_user_zone_domain(%User{} = user) do
    label =
      (user.handle || user.username)
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

  def builtin_user_zone?(%Zone{} = zone, %User{} = user) do
    zone.user_id == user.id and zone.domain == builtin_user_zone_domain(user)
  end

  def builtin_user_zone_mode(%User{} = user), do: User.built_in_subdomain_mode(user)

  def builtin_user_zone_mode(%Zone{} = zone) do
    case Repo.get(User, zone.user_id) do
      %User{} = user -> builtin_user_zone_mode(user)
      _ -> "platform"
    end
  end

  def builtin_user_zone_mode(_), do: "platform"

  def builtin_user_zone_hosted_by_platform?(user_or_zone),
    do: builtin_user_zone_mode(user_or_zone) == "platform"

  def update_builtin_user_zone_mode(%User{} = user, mode) when mode in @builtin_user_zone_modes do
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

  def update_builtin_user_zone_mode(%User{} = _user, _mode), do: {:error, :invalid_mode}

  def update_builtin_user_zone_mode(_, _), do: {:error, :invalid_user}

  def builtin_user_zone?(%Zone{} = zone) do
    case zone.user_id && Repo.get(User, zone.user_id) do
      %User{} = user -> builtin_user_zone?(zone, user)
      _ -> false
    end
  end

  def builtin_user_zone?(_), do: false

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

  def create_zone(%User{id: user_id}, attrs), do: create_zone(user_id, attrs)

  def create_zone(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %Zone{}
    |> Zone.changeset(create_zone_attrs(attrs, user_id))
    |> Repo.insert()
    |> case do
      {:ok, zone} -> {:ok, Repo.preload(zone, [:records, :service_configs])}
      error -> error
    end
    |> refresh_authority_cache_after_write()
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
      |> refresh_authority_cache_after_write()
    end
  end

  def create_record(zone_id, attrs) when is_integer(zone_id) and is_map(attrs) do
    zone_domain = zone_domain(zone_id)

    %Record{}
    |> Record.changeset(normalize_record_attrs(Map.put(attrs, "zone_id", zone_id), zone_domain))
    |> Repo.insert()
    |> refresh_authority_cache_after_write()
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
      |> refresh_authority_cache_after_write()
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
      |> refresh_authority_cache_after_write()
    end
  end

  def delete_record(%Record{} = record) do
    with :ok <- validate_record_mutation(record, :delete) do
      record
      |> Repo.delete()
      |> refresh_authority_cache_after_write()
    end
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
      |> refresh_authority_cache_after_write()
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
      ManagedRecords.apply_service(zone, service, %{"enabled" => false})
    end
  end

  def zone_service_health(%Zone{} = zone), do: ManagedRecords.service_health(zone)

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

  def supported_record_types, do: @record_types

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
    attrs = %{
      zone_id: zone_id,
      query_date: Date.utc_today(),
      qname: normalize_dns_name(result.qname),
      qtype: normalize_dns_metric_value(result.qtype),
      rcode: normalize_dns_metric_value(result.rcode),
      transport: transport,
      query_count: 1
    }

    %QueryStat{}
    |> QueryStat.changeset(attrs)
    |> Repo.insert(
      on_conflict: [inc: [query_count: 1]],
      conflict_target: [:zone_id, :query_date, :qname, :qtype, :rcode, :transport],
      returning: false
    )

    :ok
  rescue
    _ -> :ok
  end

  def track_query(_result, _transport), do: :ok

  def get_zone_query_stats(zone_id) when is_integer(zone_id) do
    today = Date.utc_today()
    week_ago = Date.add(today, -6)

    %{
      total_queries: total_queries(zone_id),
      queries_today: queries_since(zone_id, today),
      queries_this_week: queries_since(zone_id, week_ago),
      nxdomain_queries: rcode_queries(zone_id, "NXDOMAIN")
    }
  end

  def get_zone_query_stats(_), do: empty_query_stats()

  def get_zone_daily_query_counts(zone_id, days \\ 30)

  def get_zone_daily_query_counts(zone_id, days) when is_integer(zone_id) and days > 0 do
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

  def get_zone_query_type_breakdown(zone_id, limit \\ 10)

  def get_zone_query_type_breakdown(zone_id, limit) when is_integer(zone_id) do
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id,
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
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id,
      group_by: qs.qname,
      select: %{qname: qs.qname, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.qname],
      limit: ^limit
    )
    |> Repo.all()
  end

  def get_zone_top_names(_, _), do: []

  def get_zone_rcode_breakdown(zone_id) when is_integer(zone_id) do
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id,
      group_by: qs.rcode,
      select: %{rcode: qs.rcode, count: sum(qs.query_count)},
      order_by: [desc: sum(qs.query_count), asc: qs.rcode]
    )
    |> Repo.all()
  end

  def get_zone_rcode_breakdown(_), do: []

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

  defp verify_nameservers(%Zone{domain: domain}) do
    if public_hostname?(domain) do
      expected = nameservers() |> Enum.map(&normalize_hostname/1) |> Enum.sort()
      resolved = lookup_dns_values(domain, :ns, timeout: 5_000) |> Enum.sort()

      if expected == resolved,
        do: :ok,
        else: {:error, delegation_mismatch_message(expected, resolved)}
    else
      {:error, "Zone verification only supports public DNS domains"}
    end
  rescue
    error -> {:error, "NS lookup failed for #{domain}: #{inspect(error)}"}
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

  defp delegated_to_elektrine?(observed_nameservers) do
    expected = nameservers() |> Enum.map(&normalize_hostname/1) |> Enum.sort()
    Enum.sort(observed_nameservers) == expected
  end

  defp provider_hint([]), do: nil

  defp provider_hint(nameservers) do
    joined = Enum.join(nameservers, " ")

    cond do
      String.contains?(joined, "cloudflare.com") -> "Cloudflare"
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

  defp total_queries(zone_id) do
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id,
      select: sum(qs.query_count)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp queries_since(zone_id, start_date) do
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.query_date >= ^start_date,
      select: sum(qs.query_count)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp rcode_queries(zone_id, rcode) do
    from(qs in QueryStat,
      where: qs.zone_id == ^zone_id and qs.rcode == ^rcode,
      select: sum(qs.query_count)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp normalize_dns_metric_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_dns_metric_value(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_dns_metric_value(value), do: value |> to_string() |> String.upcase()

  defp normalize_dns_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_dns_name(value), do: value |> to_string() |> normalize_dns_name()

  defp refresh_authority_cache_after_write({:ok, _result} = result) do
    refresh_authority_cache()
    result
  end

  defp refresh_authority_cache_after_write(result), do: result

  defp refresh_authority_cache do
    case Process.whereis(ZoneCache) do
      nil -> :ok
      _pid -> ZoneCache.refresh(caller: self())
    end
  end

  defp ensure_builtin_user_zone(%User{} = user, domain) do
    zone =
      Zone
      |> where([z], z.user_id == ^user.id and fragment("lower(?)", z.domain) == ^domain)
      |> preload([:records, :service_configs])
      |> Repo.one()

    case zone do
      %Zone{} = existing ->
        ensure_builtin_user_zone_records(existing)

      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          zone =
            %Zone{}
            |> Zone.changeset(%{
              domain: domain,
              user_id: user.id,
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
            refresh_authority_cache()
            {:ok, zone}

          other ->
            other
        end
    end
  end

  defp ensure_builtin_user_zone_records(%Zone{} = zone) do
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
          refresh_authority_cache()
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
    if builtin_user_zone?(zone) and builtin_user_zone_hosted_by_platform?(zone) do
      validate_builtin_zone_record_write(zone, attrs)
    else
      :ok
    end
  end

  defp validate_zone_record_write(_, _), do: :ok

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
    if protected_builtin_zone_record?(record) do
      message =
        case action do
          :delete -> "is managed by Elektrine and cannot be deleted"
          _ -> "is managed by Elektrine and cannot be modified"
        end

      {:error, add_error(change(record), :name, message)}
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

  defp validate_platform_handoff(%User{} = user) do
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

  defp zone_domain(zone_id) when is_integer(zone_id) do
    case Repo.get(Zone, zone_id) do
      %Zone{domain: domain} -> domain
      _ -> nil
    end
  end

  defp zone_domain(_), do: nil
end
