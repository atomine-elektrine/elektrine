defmodule Elektrine.DNS.DomainHealth do
  @moduledoc """
  Local domain posture checks for a managed DNS zone.

  These checks intentionally use the records stored in Elektrine. Delegation and
  live delivery signals are represented as review items when they need external
  network or reputation-provider confirmation.
  """

  alias Elektrine.DNS.Zone

  @statuses [:ok, :review, :warning, :missing]

  def analyze(%Zone{} = zone) do
    records = List.wrap(zone.records)
    checks = checks(zone, records)

    %{
      domain: zone.domain,
      status: overall_status(checks),
      score: score(checks),
      summary: summary(checks),
      checks: checks,
      recommendations: recommendations(checks)
    }
  end

  def analyze(_), do: empty()

  defp empty do
    %{
      domain: nil,
      status: :missing,
      score: 0,
      summary: "No zone selected.",
      checks: [],
      recommendations: []
    }
  end

  defp checks(zone, records) do
    [
      delegation_check(zone),
      mx_check(records),
      spf_check(records),
      dkim_check(records),
      dmarc_check(records),
      caa_check(records),
      dnssec_check(records),
      mta_sts_check(records),
      tls_rpt_check(records),
      tls_certificate_check(zone, records),
      blacklist_check(records)
    ]
  end

  defp delegation_check(%Zone{status: "verified"}) do
    check(:dns, "Nameserver delegation", :ok, "Zone delegation is verified.", nil)
  end

  defp delegation_check(%Zone{last_error: last_error})
       when is_binary(last_error) and last_error != "" do
    check(
      :dns,
      "Nameserver delegation",
      :warning,
      last_error,
      "Point the domain's NS records at the Elektrine nameservers, then verify the zone again."
    )
  end

  defp delegation_check(_zone) do
    check(
      :dns,
      "Nameserver delegation",
      :review,
      "Zone delegation has not been verified yet.",
      "Verify the zone after updating registrar nameservers."
    )
  end

  defp mx_check(records) do
    case records_of(records, "MX", "@") do
      [] ->
        check(
          :mail,
          "MX records",
          :missing,
          "No apex MX record is configured.",
          "Add an MX record that points to the mail host for this domain."
        )

      mx_records ->
        targets = Enum.map_join(mx_records, ", ", & &1.content)
        check(:mail, "MX records", :ok, "Mail routes to #{targets}.", nil)
    end
  end

  defp spf_check(records) do
    spf = txt_record(records, "@", "v=spf1")

    cond do
      is_nil(spf) ->
        check(
          :mail,
          "SPF policy",
          :missing,
          "No SPF TXT record was found at the apex.",
          "Add an SPF record such as `v=spf1 mx -all`."
        )

      String.contains?(String.downcase(spf.content), [" -all", "~all"]) ->
        check(
          :mail,
          "SPF policy",
          :ok,
          "SPF policy is present and has an explicit all mechanism.",
          nil
        )

      true ->
        check(
          :mail,
          "SPF policy",
          :review,
          "SPF exists but does not end with `-all` or `~all`.",
          "Tighten the SPF policy once all legitimate senders are listed."
        )
    end
  end

  defp dkim_check(records) do
    dkim =
      Enum.find(records, fn record ->
        record.type == "TXT" and String.contains?(record.name || "", "_domainkey") and
          contains_ci?(record.content, "v=DKIM1")
      end)

    if dkim do
      check(:mail, "DKIM key", :ok, "DKIM TXT key is published at #{dkim.name}.", nil)
    else
      check(
        :mail,
        "DKIM key",
        :missing,
        "No DKIM TXT key was found.",
        "Enable the managed email template or publish a selector under `<selector>._domainkey`."
      )
    end
  end

  defp dmarc_check(records) do
    dmarc = txt_record(records, "_dmarc", "v=DMARC1")

    cond do
      is_nil(dmarc) ->
        check(
          :mail,
          "DMARC policy",
          :missing,
          "No DMARC TXT record was found.",
          "Add `_dmarc` with `v=DMARC1; p=quarantine` or stronger."
        )

      contains_ci?(dmarc.content, "p=reject") or contains_ci?(dmarc.content, "p=quarantine") ->
        check(:mail, "DMARC policy", :ok, "DMARC is enforcing with quarantine or reject.", nil)

      contains_ci?(dmarc.content, "p=none") ->
        check(
          :mail,
          "DMARC policy",
          :review,
          "DMARC is monitoring only with `p=none`.",
          "Move to `p=quarantine` or `p=reject` after reviewing reports."
        )

      true ->
        check(
          :mail,
          "DMARC policy",
          :review,
          "DMARC exists but the policy could not be classified.",
          "Review the DMARC TXT value for a valid `p=` policy."
        )
    end
  end

  defp caa_check(records) do
    case records_of(records, "CAA", "@") do
      [] ->
        check(
          :tls,
          "CAA records",
          :review,
          "No CAA records restrict certificate issuance.",
          "Add CAA records for the certificate authorities you use."
        )

      caa_records ->
        issuers = Enum.map_join(caa_records, ", ", & &1.content)
        check(:tls, "CAA records", :ok, "CAA policy is published: #{issuers}.", nil)
    end
  end

  defp dnssec_check(records) do
    if Enum.any?(records, &(&1.type in ["DS", "DNSKEY"])) do
      check(:dns, "DNSSEC material", :ok, "DNSSEC DS or DNSKEY material is present.", nil)
    else
      check(
        :dns,
        "DNSSEC material",
        :review,
        "No DNSSEC DS or DNSKEY records are tracked in this zone.",
        "Enable DNSSEC at the registrar/provider when supported."
      )
    end
  end

  defp mta_sts_check(records) do
    if txt_record(records, "_mta-sts", "v=STSv1") do
      check(:mail, "MTA-STS policy", :ok, "MTA-STS TXT policy marker is published.", nil)
    else
      check(
        :mail,
        "MTA-STS policy",
        :review,
        "No `_mta-sts` TXT marker was found.",
        "Publish MTA-STS records when HTTPS policy hosting is available."
      )
    end
  end

  defp tls_rpt_check(records) do
    if txt_record(records, "_smtp._tls", "v=TLSRPTv1") do
      check(:mail, "SMTP TLS reports", :ok, "TLS-RPT reporting is configured.", nil)
    else
      check(
        :mail,
        "SMTP TLS reports",
        :review,
        "No SMTP TLS-RPT record was found.",
        "Add `_smtp._tls` with a `rua=mailto:` destination."
      )
    end
  end

  defp tls_certificate_check(%Zone{force_https: true}, records) do
    if web_records?(records) do
      check(
        :tls,
        "TLS certificate",
        :ok,
        "HTTPS is required for this zone and web host records are present.",
        nil
      )
    else
      check(
        :tls,
        "TLS certificate",
        :review,
        "HTTPS is required, but no apex or `www` web records are present.",
        "Point the domain at a web host that can issue a certificate."
      )
    end
  end

  defp tls_certificate_check(_zone, records) do
    if web_records?(records) do
      check(
        :tls,
        "TLS certificate",
        :review,
        "Web host records exist, but live certificate expiry is not monitored yet.",
        "Verify the HTTPS certificate for apex and `www`, or enable force HTTPS once certificates are issued."
      )
    else
      check(
        :tls,
        "TLS certificate",
        :review,
        "No apex or `www` web records were found.",
        "Add web records before expecting a browser TLS certificate."
      )
    end
  end

  defp blacklist_check(records) do
    if records_of(records, "MX", "@") == [] do
      check(
        :deliverability,
        "Blacklist monitor",
        :review,
        "Blacklist checks need a sending mail host or IP.",
        "Add MX/mail host records, then check sender IPs against reputation providers."
      )
    else
      check(
        :deliverability,
        "Blacklist monitor",
        :review,
        "External blacklist providers are not queried by this local dashboard.",
        "Check outbound mail server IPs against common RBLs before production sending."
      )
    end
  end

  defp check(category, label, status, detail, fix) when status in @statuses do
    %{category: category, label: label, status: status, detail: detail, fix: fix}
  end

  defp records_of(records, type, name) do
    Enum.filter(records, &(&1.type == type and normalize_name(&1.name) == normalize_name(name)))
  end

  defp txt_record(records, name, prefix) do
    Enum.find(records, fn record ->
      record.type == "TXT" and normalize_name(record.name) == normalize_name(name) and
        contains_ci?(record.content, prefix)
    end)
  end

  defp web_records?(records) do
    Enum.any?(records, fn record ->
      record.type in ["A", "AAAA", "ALIAS", "CNAME", "HTTPS"] and
        normalize_name(record.name) in ["@", "www"]
    end)
  end

  defp contains_ci?(value, needle) when is_binary(value) do
    String.contains?(String.downcase(value), String.downcase(needle))
  end

  defp contains_ci?(_, _), do: false

  defp normalize_name(nil), do: ""

  defp normalize_name(name),
    do: name |> String.trim() |> String.trim_trailing(".") |> String.downcase()

  defp overall_status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :missing)) -> :missing
      Enum.any?(checks, &(&1.status == :warning)) -> :warning
      Enum.any?(checks, &(&1.status == :review)) -> :review
      true -> :ok
    end
  end

  defp score(checks) do
    earned = Enum.sum(Enum.map(checks, &check_score/1))
    max = length(checks) * 2

    round(earned / max * 100)
  end

  defp check_score(%{status: :ok}), do: 2
  defp check_score(%{status: :review}), do: 1
  defp check_score(_), do: 0

  defp summary(checks) do
    ok = Enum.count(checks, &(&1.status == :ok))
    review = Enum.count(checks, &(&1.status == :review))
    action = Enum.count(checks, &(&1.status in [:missing, :warning]))

    "#{ok} passing, #{review} to review, #{action} need action."
  end

  defp recommendations(checks) do
    checks
    |> Enum.reject(&is_nil(&1.fix))
    |> Enum.map(&%{label: &1.label, fix: &1.fix, status: &1.status})
  end
end
