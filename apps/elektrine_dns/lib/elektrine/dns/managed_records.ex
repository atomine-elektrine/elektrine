defmodule Elektrine.DNS.ManagedRecords do
  @moduledoc false

  import Ecto.Query, warn: false

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

    incoming_settings =
      attrs
      |> Map.get("settings", %{})
      |> normalize_settings()
      |> drop_redacted_private_settings(service)

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
                  |> Repo.insert_or_update!()

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

  def delete_service(%Zone{} = zone, service) do
    service = normalize_service(service)

    from(r in Record,
      where: r.zone_id == ^zone.id and r.service == ^service and r.managed == true
    )
    |> Repo.delete_all()
  end

  def service_status(%Zone{} = zone, service) do
    Repo.get_by(ZoneServiceConfig, zone_id: zone.id, service: normalize_service(service))
  end

  def list_service_configs(zone_id) do
    from(c in ZoneServiceConfig, where: c.zone_id == ^zone_id, order_by: c.service)
    |> Repo.all()
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

      desired =
        if(config && config.enabled, do: desired_records(zone, service, settings), else: [])

      managed_records = list_managed_records(zone.id, service)
      conflicts = conflicts_for(zone, service, desired)
      checks = health_checks(desired, managed_records, conflicts)

      %{
        service: service,
        enabled: config && config.enabled,
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
      |> Map.put(
        "dkim_value",
        dkim_module().public_key_dns_value(key_material.public_key)
        |> then(&"v=DKIM1; k=rsa; p=#{&1}")
      )
    else
      dkim_public_key = Map.get(settings, "dkim_public_key", "")
      dkim_value = "v=DKIM1; k=rsa; p=#{dkim_module().public_key_dns_value(dkim_public_key)}"

      settings
      |> Map.put_new("dkim_value", dkim_value)
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
    do: {:ok, config}

  defp finalize_side_effects(_zone, _service, %ZoneServiceConfig{status: status} = config)
       when status in ["conflict", "disabled", "pending"],
       do: {:ok, config}

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

    {:ok, updated}
  end

  defp normalize_mail_target(%Zone{} = zone, settings) do
    target = MailSecurity.mail_target(zone.domain, settings)
    default_target = MailSecurity.default_mail_target(zone)

    if target == zone.domain and default_target != zone.domain and legacy_mail_alias?(zone) do
      default_target
    else
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
