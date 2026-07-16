defmodule Elektrine.DNS.ManagedRecords do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.AppCache
  alias Elektrine.DNS.MailSecurity
  alias Elektrine.DNS.Record
  alias Elektrine.DNS.Zone
  alias Elektrine.DNS.ZoneServiceConfig
  alias Elektrine.Repo
  alias Elektrine.Secrets.EncryptedString

  @redacted_secret "[redacted]"
  @sensitive_settings ~w(dkim_private_key)

  def apply_service(%Zone{} = zone, service, attrs \\ %{}) when is_map(attrs) do
    service = normalize_service(service)

    attrs
    |> Map.get("settings", %{})
    |> normalize_settings()
    |> drop_redacted_private_settings(service)
    |> validate_settings(service)
    |> case do
      {:ok, incoming_settings} -> do_apply_service(zone, service, attrs, incoming_settings)
      {:error, _message} = error -> error
    end
  end

  defp do_apply_service(zone, service, attrs, incoming_settings) do
    enabled = Map.get(attrs, "enabled", true)
    mode = Map.get(attrs, "mode", "managed")

    tx_result =
      Repo.transaction(fn ->
        config =
          Repo.get_by(ZoneServiceConfig, zone_id: zone.id, service: service) ||
            %ZoneServiceConfig{zone_id: zone.id, service: service}

        settings =
          config.settings
          |> normalize_settings()
          |> Map.merge(incoming_settings)
          |> decrypt_private_settings(service)

        {:ok, config} =
          config
          |> ZoneServiceConfig.changeset(%{
            zone_id: zone.id,
            service: service,
            enabled: enabled,
            mode: mode,
            settings: store_private_settings(service, settings),
            status: if(enabled, do: "pending", else: "disabled"),
            last_error: nil
          })
          |> Repo.insert_or_update()

        if enabled and mode == "managed" do
          zone = Repo.preload(zone, :records, force: true)
          settings = prepare_settings(zone, service, settings)
          desired = desired_records(zone, service, settings)
          conflicts = conflicts_for(zone, service, desired)

          if conflicts == [] do
            existing = list_managed_records(zone.id, service)
            desired_keys = MapSet.new(Enum.map(desired, & &1.managed_key))

            Enum.each(existing, fn record ->
              unless MapSet.member?(desired_keys, record.managed_key) do
                Repo.delete!(record)
              end
            end)

            _adopted_ids =
              Enum.reduce(desired, MapSet.new(), fn attrs, adopted_ids ->
                record =
                  Repo.get_by(Record, zone_id: zone.id, managed_key: attrs.managed_key) ||
                    adoptable_record(zone.id, attrs, adopted_ids) || %Record{}

                updated =
                  record
                  |> Record.changeset(Map.merge(attrs, %{zone_id: zone.id}))
                  |> Repo.insert_or_update()
                  |> case do
                    {:ok, updated} -> updated
                    {:error, changeset} -> Repo.rollback(invalid_record_message(attrs, changeset))
                  end

                if record.id, do: MapSet.put(adopted_ids, updated.id), else: adopted_ids
              end)

            Repo.update!(
              ZoneServiceConfig.changeset(config, %{
                settings: store_private_settings(service, settings),
                status: "ok",
                last_applied_at: now(),
                last_error: nil
              })
            )
          else
            Repo.update!(
              ZoneServiceConfig.changeset(config, %{
                settings: store_private_settings(service, settings),
                status: "conflict",
                last_applied_at: now(),
                last_error: Enum.join(conflicts, "; ")
              })
            )
          end
        else
          delete_service(zone, service)

          Repo.update!(
            ZoneServiceConfig.changeset(config, %{
              status: if(enabled, do: "pending", else: "disabled"),
              last_applied_at: now(),
              last_error: nil
            })
          )
        end

        Repo.get_by!(ZoneServiceConfig, zone_id: zone.id, service: service)
      end)

    case tx_result do
      {:ok, config} ->
        finalize_side_effects(zone, service, config)

      other ->
        other
    end
  end

  def reconcile_supported_mail_services do
    Elektrine.Domains.supported_email_domains()
    |> Enum.map(&reconcile_supported_mail_service/1)
  end

  def delete_service(%Zone{} = zone, service) do
    service = normalize_service(service)

    from(r in Record,
      where: r.zone_id == ^zone.id and r.service == ^service and r.managed == true
    )
    |> Repo.delete_all()
  end

  defp reconcile_supported_mail_service(domain) do
    case Repo.get_by(Zone, domain: domain) do
      nil ->
        {domain, :skipped, :zone_missing}

      %Zone{} = zone ->
        case Repo.get_by(ZoneServiceConfig, zone_id: zone.id, service: "mail") do
          %ZoneServiceConfig{enabled: true, mode: "managed"} ->
            case apply_service(zone, "mail", %{}) do
              {:ok, %ZoneServiceConfig{status: "ok"}} ->
                {domain, :ok}

              {:ok, %ZoneServiceConfig{} = config} ->
                {domain, :error, config.status, config.last_error}

              {:error, reason} ->
                {domain, :error, reason}
            end

          %ZoneServiceConfig{} ->
            {domain, :skipped, :mail_not_managed}

          nil ->
            {domain, :skipped, :mail_not_configured}
        end
    end
  end

  def service_status(%Zone{} = zone, service) do
    service = normalize_service(service)

    zone.id
    |> list_service_configs()
    |> Enum.find(&(&1.service == service))
  end

  def list_service_configs(zone_id) do
    AppCache.get_dns_service_configs(zone_id, fn ->
      from(c in ZoneServiceConfig, where: c.zone_id == ^zone_id, order_by: c.service)
      |> Repo.all()
    end)
  end

  def public_settings(service, settings) do
    service = normalize_service(service)

    settings
    |> normalize_settings()
    |> redact_private_settings(service)
  end

  def service_health(%Zone{} = zone) do
    configs = list_service_configs(zone.id)

    Enum.map(ZoneServiceConfig.services(), fn service ->
      config = Enum.find(configs, &(&1.service == service))

      settings =
        config
        |> then(&(&1 && &1.settings))
        |> normalize_settings()
        |> decrypt_private_settings(service)

      planned = desired_records(zone, service, settings)
      desired = if config && config.enabled, do: planned, else: []

      managed_records = list_managed_records(zone.id, service)
      conflicts = conflicts_for(zone, service, desired)
      checks = health_checks(desired, managed_records, conflicts)

      %{
        service: service,
        enabled: config && config.enabled,
        planned_records: planned,
        mode: config && config.mode,
        status: if(config, do: config.status, else: "not_configured"),
        last_error: if(config, do: config.last_error, else: nil),
        settings: redact_private_settings(settings, service),
        desired_records: desired,
        managed_records: managed_records,
        conflicts: conflicts,
        checks: checks,
        repairable: config && config.enabled && config.mode == "managed"
      }
    end)
  end

  defp desired_records(zone, "mail", settings) do
    Elektrine.DNS.Generators.Mail.generate(zone, settings)
    |> Enum.map(&managed_attrs(&1, "mail"))
  end

  defp desired_records(zone, "web", settings) do
    Elektrine.DNS.Generators.Web.generate(zone, settings)
    |> Enum.map(&managed_attrs(&1, "web"))
  end

  defp desired_records(zone, "turn", settings) do
    Elektrine.DNS.Generators.Turn.generate(zone, settings)
    |> Enum.map(&managed_attrs(&1, "turn"))
  end

  defp desired_records(zone, "vpn", settings) do
    Elektrine.DNS.Generators.VPN.generate(zone, settings)
    |> Enum.map(&managed_attrs(&1, "vpn"))
  end

  defp desired_records(zone, "bluesky", settings) do
    Elektrine.DNS.Generators.Bluesky.generate(zone, settings)
    |> Enum.map(&managed_attrs(&1, "bluesky"))
  end

  defp desired_records(_zone, _service, _settings), do: []

  defp prepare_settings(%Zone{} = zone, "mail", settings) do
    settings
    |> Map.put_new_lazy("dkim_selector", fn ->
      dkim_module().generate_domain_key_material().selector
    end)
    |> ensure_dkim_material()
    |> put_default_setting("mail_target", MailSecurity.default_mail_target(zone))
    |> then(&Map.put(&1, "mail_target", normalize_mail_target(zone, &1)))
    |> put_default_setting("caa_issue", MailSecurity.caa_issue(%{}))
    |> put_default_setting("mta_sts_mode", "enforce")
    |> put_default_setting("tls_rpt_rua", "mailto:postmaster@#{zone.domain}")
    |> put_default_setting("tlsa_association_data", MailSecurity.default_tlsa_association_data())
  end

  defp prepare_settings(_zone, _service, settings), do: settings

  defp ensure_dkim_material(settings) do
    if blank?(settings["dkim_public_key"]) or blank?(settings["dkim_private_key"]) do
      key_material = dkim_module().generate_domain_key_material()

      settings
      |> Map.put("dkim_selector", key_material.selector)
      |> Map.put("dkim_public_key", key_material.public_key)
      |> Map.put("dkim_private_key", key_material.private_key)
      |> Map.put("dkim_value", dkim_value(key_material.public_key, key_material.private_key))
    else
      dkim_public_key = Map.get(settings, "dkim_public_key", "")
      dkim_private_key = Map.get(settings, "dkim_private_key", "")

      settings
      |> Map.put("dkim_value", dkim_value(dkim_public_key, dkim_private_key))
    end
  end

  defp dkim_value(public_key, private_key) do
    dkim = dkim_module()

    if function_exported?(dkim, :dkim_value_from_material, 2) do
      dkim.dkim_value_from_material(public_key, private_key)
    else
      "v=DKIM1; k=rsa; p=#{dkim.public_key_dns_value(public_key)}"
    end
  end

  defp sync_side_effects(zone, "mail", settings) do
    case dkim_module().sync_domain(
           zone.domain,
           settings["dkim_selector"],
           settings["dkim_private_key"]
         ) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp sync_side_effects(_zone, _service, _settings), do: nil

  defp finalize_side_effects(_zone, _service, %ZoneServiceConfig{enabled: false} = config),
    do: invalidate_and_return(config)

  defp finalize_side_effects(_zone, _service, %ZoneServiceConfig{status: status} = config)
       when status in ["conflict", "disabled", "pending"],
       do: invalidate_and_return(config)

  defp finalize_side_effects(zone, service, %ZoneServiceConfig{} = config) do
    sync_error =
      sync_side_effects(
        zone,
        service,
        config.settings
        |> normalize_settings()
        |> decrypt_private_settings(service)
      )

    updated =
      Repo.update!(
        ZoneServiceConfig.changeset(config, %{
          status: if(sync_error, do: "error", else: config.status),
          last_error: sync_error
        })
      )

    invalidate_and_return(updated)
  end

  defp invalidate_and_return(%ZoneServiceConfig{} = config) do
    AppCache.invalidate_dns_service_configs(config.zone_id)
    {:ok, config}
  end

  defp normalize_mail_target(%Zone{} = zone, settings) do
    target = MailSecurity.mail_target(zone.domain, settings)
    default_target = MailSecurity.default_mail_target(zone)

    cond do
      not Elektrine.DNS.public_hostname?(target) ->
        default_target

      target == zone.domain and default_target != zone.domain and legacy_mail_alias?(zone) ->
        default_target

      true ->
        target
    end
  end

  defp legacy_mail_alias?(%Zone{} = zone) do
    Enum.any?(List.wrap(zone.records), fn record ->
      record.managed == true and record.service == "mail" and record.managed_key == "mail:mail" and
        record.type == "CNAME" and
        normalize_domain(record.content) == normalize_domain(zone.domain)
    end)
  end

  defp managed_attrs(attrs, service) do
    attrs
    |> Map.put(:source, "system")
    |> Map.put(:service, service)
    |> Map.put(:managed, true)
  end

  defp conflicts_for(zone, _service, desired) do
    desired
    |> Enum.group_by(&{&1.name, &1.type})
    |> Enum.flat_map(fn {{name, type}, rrset} ->
      existing =
        from(r in Record,
          where:
            r.zone_id == ^zone.id and r.name == ^name and r.type == ^type and r.managed == false
        )
        |> Repo.all()

      cond do
        existing == [] ->
          []

        compatible_rrset?(existing, rrset) ->
          []

        true ->
          ["#{type} #{name} conflicts with user-managed RRset"]
      end
    end)
    |> Enum.uniq()
  end

  defp compatible_rrset?(existing, desired) do
    canonical_rrset(existing) == canonical_rrset(desired)
  end

  defp canonical_rrset(records) do
    records
    |> Enum.map(&canonical_record/1)
    |> Enum.sort()
  end

  defp canonical_record(record) do
    %{
      name: Map.get(record, :name),
      type: Map.get(record, :type),
      content: Map.get(record, :content),
      ttl: Map.get(record, :ttl),
      priority: Map.get(record, :priority),
      weight: Map.get(record, :weight),
      port: Map.get(record, :port),
      tag: Map.get(record, :tag),
      flags: Map.get(record, :flags),
      protocol: Map.get(record, :protocol),
      algorithm: Map.get(record, :algorithm),
      key_tag: Map.get(record, :key_tag),
      digest_type: Map.get(record, :digest_type),
      usage: Map.get(record, :usage),
      selector: Map.get(record, :selector),
      matching_type: Map.get(record, :matching_type),
      value: Map.get(record, :value)
    }
  end

  defp list_managed_records(zone_id, service) do
    from(r in Record,
      where: r.zone_id == ^zone_id and r.service == ^service and r.managed == true,
      order_by: [asc: r.type, asc: r.name]
    )
    |> Repo.all()
  end

  defp adoptable_record(zone_id, attrs, adopted_ids) do
    from(r in Record,
      where:
        r.zone_id == ^zone_id and r.managed == false and r.name == ^attrs.name and
          r.type == ^attrs.type,
      order_by: [asc: r.id]
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(adopted_ids, &1.id))
    |> Enum.find(&(canonical_record(&1) == canonical_record(attrs)))
  end

  defp health_checks(desired, managed_records, conflicts) do
    records_by_key = Map.new(managed_records, &{&1.managed_key, &1})

    desired_checks =
      Enum.map(desired, fn desired_record ->
        actual = Map.get(records_by_key, desired_record.managed_key)

        %{
          key: desired_record.managed_key,
          label: desired_record.metadata["label"] || desired_record.managed_key,
          required: Map.get(desired_record, :required, false),
          status: record_check_status(desired_record, actual),
          expected: desired_record,
          actual: actual
        }
      end)

    conflict_checks =
      Enum.map(conflicts, &%{key: nil, label: &1, required: true, status: "conflict"})

    desired_checks ++ conflict_checks
  end

  defp record_check_status(_desired, nil), do: "missing"

  defp record_check_status(desired, actual) do
    comparable = [
      :name,
      :type,
      :content,
      :priority,
      :port,
      :weight,
      :ttl,
      :flags,
      :tag,
      :protocol,
      :algorithm,
      :key_tag,
      :digest_type,
      :usage,
      :selector,
      :matching_type
    ]

    if Enum.all?(comparable, fn key -> Map.get(desired, key) == Map.get(actual, key) end) do
      "ok"
    else
      "drift"
    end
  end

  defp normalize_settings(nil), do: %{}

  defp normalize_settings(settings) when is_map(settings) do
    Map.new(settings, fn {k, v} -> {to_string(k), normalize_setting_value(v)} end)
  end

  defp normalize_settings(_), do: %{}

  defp normalize_setting_value(value) when value in ["true", "TRUE", "on", "ON", "yes", "YES"],
    do: true

  defp normalize_setting_value(value)
       when value in ["false", "FALSE", "off", "OFF", "no", "NO"],
       do: false

  defp normalize_setting_value(value), do: value

  @hostname_settings %{
    "web" => [{"www_target", "WWW target"}],
    "turn" => [{"turn_target", "TURN target"}],
    "vpn" => [{"vpn_target", "VPN target"}, {"vpn_api_target", "Admin/API target"}],
    "bluesky" => [{"bluesky_target", "Bluesky target"}]
  }

  @label_settings %{
    "turn" => [{"turn_host", "TURN host"}],
    "vpn" => [{"vpn_host", "VPN host"}, {"vpn_api_host", "Admin/API host"}],
    "bluesky" => [{"bluesky_host", "Bluesky host"}]
  }

  defp validate_settings(settings, service) do
    with :ok <- validate_setting_fields(settings, @hostname_settings[service], &target_error/2),
         :ok <- validate_setting_fields(settings, @label_settings[service], &label_error/2) do
      normalize_tls_rpt_setting(settings, service)
    end
  end

  defp validate_setting_fields(_settings, nil, _error_fun), do: :ok

  defp validate_setting_fields(settings, fields, error_fun) do
    Enum.find_value(fields, :ok, fn {key, label} ->
      error_fun.(label, Map.get(settings, key))
    end)
  end

  defp target_error(_label, value) when is_nil(value), do: nil

  defp target_error(label, value) do
    if blank?(value) or (is_binary(value) and Elektrine.DNS.public_hostname?(value)) do
      nil
    else
      {:error,
       "#{label} must be a public hostname like host.example.com" <>
         " (no http://, paths, IP addresses, or spaces)"}
    end
  end

  defp label_error(_label, value) when is_nil(value), do: nil

  defp label_error(label, value) do
    if blank?(value) or (is_binary(value) and valid_relative_name?(value)) do
      nil
    else
      {:error,
       "#{label} must be a subdomain name like turn or turn.eu" <>
         " (letters, digits, and hyphens only)"}
    end
  end

  defp valid_relative_name?(value) do
    normalized = normalize_domain(value)

    normalized != "" and
      normalized
      |> String.split(".")
      |> Enum.all?(&String.match?(&1, ~r/^_?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/))
  end

  defp normalize_tls_rpt_setting(settings, "mail") do
    case Map.get(settings, "tls_rpt_rua") do
      value when is_binary(value) ->
        if blank?(value) do
          {:ok, settings}
        else
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> normalize_tls_rpt_entries()
          |> case do
            {:ok, entries} -> {:ok, Map.put(settings, "tls_rpt_rua", Enum.join(entries, ","))}
            {:error, _message} = error -> error
          end
        end

      _ ->
        {:ok, settings}
    end
  end

  defp normalize_tls_rpt_setting(settings, _service), do: {:ok, settings}

  defp normalize_tls_rpt_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_tls_rpt_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_tls_rpt_entry("mailto:" <> address = entry) do
    if email_address?(address) do
      {:ok, entry}
    else
      {:error, "TLS-RPT rua must use a valid email address, got #{entry}"}
    end
  end

  defp normalize_tls_rpt_entry("https://" <> _ = entry), do: {:ok, entry}

  defp normalize_tls_rpt_entry(entry) do
    if email_address?(entry) do
      {:ok, "mailto:" <> entry}
    else
      {:error,
       "TLS-RPT rua must be an email address (reports@example.com) or an https:// URL," <>
         " got #{entry}"}
    end
  end

  defp email_address?(value) do
    case String.split(value, "@") do
      [local, domain] -> local != "" and Elektrine.DNS.public_hostname?(domain)
      _ -> false
    end
  end

  defp invalid_record_message(attrs, changeset) do
    label = attrs.metadata["label"] || attrs.managed_key

    details =
      Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)

    "cannot apply #{attrs.type} record for #{label}: #{details}"
  end

  defp drop_redacted_private_settings(settings, service) do
    Map.reject(settings, fn {key, value} ->
      private_setting?(service, key) and value == @redacted_secret
    end)
  end

  defp redact_private_settings(settings, service) do
    Map.new(settings, fn {key, value} ->
      if private_setting?(service, key) and not blank?(value) do
        {key, @redacted_secret}
      else
        {key, value}
      end
    end)
  end

  defp decrypt_private_settings(settings, service) do
    update_private_settings(settings, service, &decrypt_secret/1)
  end

  defp store_private_settings(service, settings) do
    update_private_settings(settings, service, &encrypt_secret/1)
  end

  defp update_private_settings(settings, service, fun) do
    Enum.reduce(@sensitive_settings, settings, fn key, acc ->
      if private_setting?(service, key) and Map.has_key?(acc, key) do
        Map.update!(acc, key, fun)
      else
        acc
      end
    end)
  end

  defp private_setting?("mail", "dkim_private_key"), do: true
  defp private_setting?(_service, _key), do: false

  defp encrypt_secret(value) when is_binary(value) do
    if EncryptedString.encrypted?(value) do
      value
    else
      case EncryptedString.encrypt(value) do
        {:ok, encrypted} -> encrypted
        :error -> value
      end
    end
  end

  defp encrypt_secret(value), do: value

  defp decrypt_secret(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      :error -> value
    end
  end

  defp decrypt_secret(value), do: value

  defp blank?(value) when is_binary(value), do: not Elektrine.Strings.present?(value)
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp normalize_domain(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> String.trim_trailing(".")

  defp normalize_domain(value), do: value |> to_string() |> normalize_domain()

  defp put_default_setting(settings, key, value) do
    if blank?(Map.get(settings, key)) do
      Map.put(settings, key, value)
    else
      settings
    end
  end

  defp dkim_module,
    do: Application.get_env(:elektrine, :managed_dns_dkim_module, Elektrine.Email.DKIM)

  defp normalize_service(service) when is_binary(service), do: String.downcase(service)
  defp normalize_service(service), do: to_string(service) |> String.downcase()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
