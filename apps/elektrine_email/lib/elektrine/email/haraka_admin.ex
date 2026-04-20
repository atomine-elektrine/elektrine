defmodule Elektrine.Email.HarakaAdmin do
  @moduledoc false

  alias Elektrine.Domains
  alias Elektrine.Email.DKIM
  alias Elektrine.EmailConfig
  alias Elektrine.RuntimeEnv

  def overview do
    domains = Domains.supported_email_domains()
    domain_diagnostics = Enum.map(domains, &domain_diagnostic/1)

    %{
      base_url: lookup_base_url(),
      send_base_url: EmailConfig.haraka_base_url(),
      api_key_configured: present?(EmailConfig.haraka_api_key()),
      primary_domain: Domains.primary_email_domain(),
      supported_domains: domains,
      mx_host: DKIM.mx_host(),
      mx_priority: DKIM.mx_priority(),
      spf_value: DKIM.spf_value(),
      dmarc_value: DKIM.dmarc_value(),
      domain_diagnostics: domain_diagnostics,
      haraka_status: overall_status(domain_diagnostics)
    }
  end

  defp domain_diagnostic(domain) do
    case DKIM.fetch_domain(domain) do
      {:ok, fetched} ->
        %{
          domain: domain,
          status: :ok,
          selector: fetched.selector,
          host: fetched.host,
          value: fetched.value,
          public_key_present: present?(fetched.public_key),
          private_key_present: fetched.private_key_present,
          notes: fetched.notes
        }

      {:error, reason} ->
        %{
          domain: domain,
          status: :error,
          error: reason,
          host: nil,
          value: nil,
          selector: nil,
          public_key_present: false,
          private_key_present: false,
          notes: []
        }
    end
  end

  defp overall_status([]), do: :unknown

  defp overall_status(domain_diagnostics) do
    cond do
      Enum.any?(domain_diagnostics, &(&1.status == :ok)) -> :connected
      Enum.any?(domain_diagnostics, &(&1.status == :error)) -> :error
      true -> :unknown
    end
  end

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(_), do: false

  defp lookup_base_url do
    RuntimeEnv.app_config(:email, [])
    |> Keyword.get(:custom_domain_haraka_base_url, EmailConfig.haraka_base_url())
  end
end
