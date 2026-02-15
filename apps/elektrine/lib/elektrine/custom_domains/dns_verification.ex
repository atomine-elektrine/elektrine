defmodule Elektrine.CustomDomains.DNSVerification do
  @moduledoc """
  DNS verification for custom domain ownership and email configuration.

  ## Domain Ownership Verification

  Verifies that the user owns a domain by checking for a specific TXT record:

      _elektrine.example.com TXT "elektrine-verify=<token>"

  This proves the user has control over the domain's DNS settings.

  ## Email DNS Verification

  For email support, additional records must be configured:

  - MX record pointing to our mail server
  - SPF TXT record authorizing our servers to send email
  - DKIM TXT record with the domain's public key
  - DMARC TXT record for email authentication policy
  """

  require Logger

  @dns_timeout 5_000
  @dns_retries 2

  # Email server configuration
  @mx_host "mx.elektrine.com"
  @spf_include "include:elektrine.com"

  @doc """
  Verifies domain ownership by checking DNS TXT record.

  Looks for: `_elektrine.{domain}` TXT record containing `elektrine-verify={token}`

  Returns:
  - `:ok` if verification successful
  - `{:error, :no_record}` if TXT record not found
  - `{:error, :token_mismatch}` if record exists but token doesn't match
  - `{:error, :dns_error}` if DNS lookup failed
  """
  def verify(domain, expected_token) do
    hostname = "_elektrine.#{domain}"
    expected_value = "elektrine-verify=#{expected_token}"

    Logger.debug("Verifying DNS TXT record for #{hostname}, expecting: #{expected_value}")

    case lookup_txt_records(hostname) do
      {:ok, records} ->
        Logger.debug("Found TXT records: #{inspect(records)}")

        if Enum.any?(records, &(&1 == expected_value)) do
          Logger.info("Domain verification successful for #{domain}")
          :ok
        else
          Logger.info("Domain verification failed for #{domain}: token mismatch")
          {:error, :token_mismatch}
        end

      {:error, :nxdomain} ->
        Logger.info("Domain verification failed for #{domain}: no TXT record")
        {:error, :no_record}

      {:error, :no_data} ->
        Logger.info("Domain verification failed for #{domain}: no TXT record")
        {:error, :no_record}

      {:error, reason} ->
        Logger.warning("DNS lookup failed for #{domain}: #{inspect(reason)}")
        {:error, :dns_error}
    end
  end

  @doc """
  Checks if the domain has proper A record pointing to our server.

  This is informational only - not required for verification,
  but helps users troubleshoot connectivity issues.
  """
  def check_a_record(domain, expected_ip) do
    case lookup_a_records(domain) do
      {:ok, ips} ->
        expected_tuple = parse_ip(expected_ip)

        if expected_tuple in ips do
          :ok
        else
          {:error, :wrong_ip, ips}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Checks if MX records are properly configured for email.

  The MX record should point to our mail server: #{@mx_host}
  """
  def check_mx_record(domain, expected_mx \\ @mx_host) do
    case lookup_mx_records(domain) do
      {:ok, mx_records} ->
        expected_lower = String.downcase(expected_mx)

        if Enum.any?(mx_records, fn {_priority, mx} ->
             String.downcase(to_string(mx)) == expected_lower or
               String.downcase(to_string(mx)) == expected_lower <> "."
           end) do
          :ok
        else
          {:error, :wrong_mx, mx_records}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies that SPF record is properly configured to include our servers.

  Expected SPF record should include: `include:elektrine.com`

  Example valid SPF: `v=spf1 include:elektrine.com ~all`
  """
  def check_spf_record(domain) do
    case lookup_txt_records(domain) do
      {:ok, records} ->
        spf_records = Enum.filter(records, &String.starts_with?(&1, "v=spf1"))

        case spf_records do
          [] ->
            {:error, :no_spf}

          [spf | _] ->
            if String.contains?(spf, @spf_include) do
              :ok
            else
              {:error, :missing_include, spf}
            end
        end

      {:error, :nxdomain} ->
        {:error, :no_spf}

      {:error, :no_data} ->
        {:error, :no_spf}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies that DKIM record is properly configured with the domain's public key.

  Checks for: `{selector}._domainkey.{domain}` TXT record

  The record should contain: `v=DKIM1; k=rsa; p={public_key_base64}`
  """
  def check_dkim_record(domain, selector, expected_public_key) do
    hostname = "#{selector}._domainkey.#{domain}"

    case lookup_txt_records(hostname) do
      {:ok, records} ->
        # Find DKIM record
        dkim_records = Enum.filter(records, &String.contains?(&1, "v=DKIM1"))

        case dkim_records do
          [] ->
            {:error, :no_dkim}

          [dkim | _] ->
            # Extract public key from record (p=<key>)
            if contains_public_key?(dkim, expected_public_key) do
              :ok
            else
              {:error, :wrong_key, dkim}
            end
        end

      {:error, :nxdomain} ->
        {:error, :no_dkim}

      {:error, :no_data} ->
        {:error, :no_dkim}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies that DMARC record exists for the domain.

  Checks for: `_dmarc.{domain}` TXT record starting with `v=DMARC1`

  DMARC is recommended but not strictly required for email to work.
  """
  def check_dmarc_record(domain) do
    hostname = "_dmarc.#{domain}"

    case lookup_txt_records(hostname) do
      {:ok, records} ->
        dmarc_records = Enum.filter(records, &String.starts_with?(&1, "v=DMARC1"))

        case dmarc_records do
          [] -> {:error, :no_dmarc}
          [_dmarc | _] -> :ok
        end

      {:error, :nxdomain} ->
        {:error, :no_dmarc}

      {:error, :no_data} ->
        {:error, :no_dmarc}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies all email DNS records for a custom domain.

  Returns a map with verification status for each record type:

      %{
        mx: :ok | {:error, reason},
        spf: :ok | {:error, reason},
        dkim: :ok | {:error, reason},
        dmarc: :ok | {:error, reason}
      }
  """
  def verify_email_dns(domain, dkim_selector, dkim_public_key) do
    %{
      mx: check_mx_record(domain),
      spf: check_spf_record(domain),
      dkim: check_dkim_record(domain, dkim_selector, dkim_public_key),
      dmarc: check_dmarc_record(domain)
    }
  end

  @doc """
  Returns the required DNS records for email configuration as a list of instructions.
  """
  def email_dns_instructions(domain, dkim_selector, dkim_public_key) do
    [
      %{
        type: :mx,
        name: domain,
        value: "10 #{@mx_host}",
        description: "Mail exchanger record - routes email to our servers"
      },
      %{
        type: :txt,
        name: domain,
        value: "v=spf1 #{@spf_include} ~all",
        description: "SPF record - authorizes our servers to send email for your domain"
      },
      %{
        type: :txt,
        name: "#{dkim_selector}._domainkey.#{domain}",
        value: "v=DKIM1; k=rsa; p=#{dkim_public_key}",
        description: "DKIM record - cryptographic signature for email authentication"
      },
      %{
        type: :txt,
        name: "_dmarc.#{domain}",
        value: "v=DMARC1; p=quarantine; rua=mailto:dmarc@#{domain}",
        description: "DMARC record - email authentication policy (recommended)"
      }
    ]
  end

  ## Private functions

  defp contains_public_key?(dkim_record, expected_key) do
    # Normalize both keys (remove whitespace, compare)
    normalized_expected = String.replace(expected_key, ~r/\s+/, "")

    # Extract p= value from DKIM record
    case Regex.run(~r/p=([^;\s]+)/, dkim_record) do
      [_, key] ->
        normalized_key = String.replace(key, ~r/\s+/, "")
        normalized_key == normalized_expected

      nil ->
        false
    end
  end

  defp lookup_txt_records(hostname) do
    hostname_charlist = to_charlist(hostname)

    with_retries(@dns_retries, fn ->
      case :inet_res.lookup(hostname_charlist, :in, :txt, timeout: @dns_timeout) do
        [] ->
          # Empty result could be NXDOMAIN or just no TXT records
          # Try to distinguish by checking if domain exists at all
          case :inet_res.gethostbyname(hostname_charlist, :inet, @dns_timeout) do
            {:ok, _} -> {:ok, []}
            {:error, :nxdomain} -> {:error, :nxdomain}
            {:error, _} -> {:ok, []}
          end

        records when is_list(records) ->
          # TXT records come as list of charlists, need to convert
          txt_values =
            Enum.map(records, fn record ->
              record
              |> List.flatten()
              |> IO.iodata_to_binary()
            end)

          {:ok, txt_values}
      end
    end)
  end

  defp lookup_a_records(hostname) do
    hostname_charlist = to_charlist(hostname)

    with_retries(@dns_retries, fn ->
      case :inet_res.lookup(hostname_charlist, :in, :a, timeout: @dns_timeout) do
        [] -> {:error, :no_record}
        ips when is_list(ips) -> {:ok, ips}
      end
    end)
  end

  defp lookup_mx_records(hostname) do
    hostname_charlist = to_charlist(hostname)

    with_retries(@dns_retries, fn ->
      case :inet_res.lookup(hostname_charlist, :in, :mx, timeout: @dns_timeout) do
        [] -> {:error, :no_record}
        records when is_list(records) -> {:ok, records}
      end
    end)
  end

  defp with_retries(0, _fun), do: {:error, :dns_error}

  defp with_retries(retries, fun) do
    case fun.() do
      {:error, :timeout} ->
        Process.sleep(500)
        with_retries(retries - 1, fun)

      {:error, :dns_error} ->
        Process.sleep(500)
        with_retries(retries - 1, fun)

      result ->
        result
    end
  rescue
    _ ->
      Process.sleep(500)
      with_retries(retries - 1, fun)
  end

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end
end
