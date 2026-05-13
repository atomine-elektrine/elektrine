defmodule Elektrine.Email.Deliverability do
  @moduledoc """
  Deliverability health checks for outbound domains.

  These checks are intentionally side-effect free so they can back admin health
  screens and preflight custom-domain sending without blocking normal delivery.
  """

  def check_domain(nil), do: %{domain: nil, spf: :missing, dmarc: :missing, mx: :missing}

  def check_domain(domain) do
    domain = domain |> to_string() |> String.trim() |> String.downcase()

    %{
      domain: domain,
      mx: dns_present?(domain, :mx),
      spf: spf_status(domain),
      dmarc: dmarc_status(domain),
      dkim: :not_checked,
      reverse_dns: :not_checked
    }
  end

  def outbound_allowed?(from_address, user_id)
      when is_binary(from_address) and is_integer(user_id) do
    domain = email_domain(from_address)

    cond do
      is_nil(domain) ->
        {:error, :invalid_sender_domain}

      domain in Elektrine.Domains.supported_email_domains() ->
        :ok

      true ->
        validate_custom_domain(domain, user_id)
    end
  end

  def outbound_allowed?(_, _), do: {:error, :invalid_sender_domain}

  defp validate_custom_domain(domain, user_id) do
    case Elektrine.Email.CustomDomains.get_verified_custom_domain(domain) do
      %{user_id: ^user_id, dkim_synced_at: synced_at, dkim_last_error: error}
      when not is_nil(synced_at) and (is_nil(error) or error == "") ->
        if enforce_dns_health?() do
          validate_dns_health(domain)
        else
          :ok
        end

      %{user_id: ^user_id} ->
        {:error, :custom_domain_dkim_not_ready}

      %{user_id: _other_user_id} ->
        {:error, :custom_domain_not_owned}

      nil ->
        {:error, :custom_domain_not_verified}
    end
  end

  defp validate_dns_health(domain) do
    health = check_domain(domain)

    if health.mx == :present and health.spf == :present and health.dmarc == :present do
      :ok
    else
      {:error, {:custom_domain_dns_unhealthy, health}}
    end
  end

  defp enforce_dns_health? do
    Application.get_env(:elektrine, :enforce_custom_domain_dns_health, false) == true
  end

  defp spf_status(domain) do
    domain
    |> txt_records()
    |> Enum.any?(&String.starts_with?(&1, "v=spf1"))
    |> present_status()
  end

  defp dmarc_status(domain) do
    "_dmarc.#{domain}"
    |> txt_records()
    |> Enum.any?(&String.starts_with?(&1, "v=DMARC1"))
    |> present_status()
  end

  defp dns_present?(domain, type) do
    case :inet_res.lookup(String.to_charlist(domain), :in, type) do
      [] -> :missing
      _ -> :present
    end
  rescue
    _ -> :unknown
  end

  defp txt_records(domain) do
    domain
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :txt)
    |> Enum.map(fn chunks -> chunks |> List.flatten() |> to_string() end)
  rescue
    _ -> []
  end

  defp present_status(true), do: :present
  defp present_status(false), do: :missing

  defp email_domain(address) do
    address
    |> Elektrine.Email.extract_email_address()
    |> String.split("@", parts: 2)
    |> case do
      [_local, domain] -> domain |> String.trim() |> String.downcase()
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
