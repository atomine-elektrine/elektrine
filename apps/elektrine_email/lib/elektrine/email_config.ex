defmodule Elektrine.EmailConfig do
  @moduledoc false

  alias Elektrine.EmailAddresses
  alias Elektrine.RuntimeEnv
  alias Elektrine.RuntimeSecrets

  def haraka_base_url(default \\ nil) do
    [
      RuntimeEnv.present("HARAKA_BASE_URL"),
      default,
      mailer_config()[:base_url],
      EmailAddresses.mail_base_url()
    ]
    |> Enum.find_value(&present_string/1)
    |> normalize_base_url()
  end

  def haraka_api_key(default \\ nil) do
    [
      RuntimeEnv.present("HARAKA_HTTP_API_KEY"),
      RuntimeEnv.present("HARAKA_OUTBOUND_API_KEY"),
      RuntimeEnv.present("HARAKA_API_KEY"),
      RuntimeEnv.present("INTERNAL_API_KEY"),
      default,
      mailer_config()[:api_key]
    ]
    |> Enum.find_value(&present_string/1)
  end

  def internal_signing_secret do
    RuntimeSecrets.haraka_internal_signing_secret() || email_setting(:internal_signing_secret)
  end

  def receiver_webhook_secret do
    RuntimeSecrets.email_receiver_webhook_secret() || email_setting(:receiver_webhook_secret)
  end

  def allow_insecure_receiver_webhook? do
    email_setting(:allow_insecure_receiver_webhook, true)
  end

  def use_external_delivery_api? do
    not RuntimeEnv.truthy?("USE_LOCAL_EMAIL") and RuntimeEnv.environment() != :test
  end

  def email_setting(key, default \\ nil) when is_atom(key) do
    RuntimeEnv.app_config(:email, [])
    |> Keyword.get(key, default)
  end

  def mailer_setting(key, default \\ nil) when is_atom(key) do
    mailer_config()
    |> Keyword.get(key, default)
  end

  def haraka_http_client do
    email_setting(:haraka_http_client, FinchClient)
  end

  defp mailer_config do
    RuntimeEnv.module_config(Elektrine.Mailer, [])
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  defp normalize_base_url(base_url) when is_binary(base_url) do
    legacy_base_url = "https://haraka." <> Elektrine.Domains.primary_email_domain()

    base_url
    |> String.trim_trailing("/")
    |> case do
      normalized when normalized == legacy_base_url ->
        EmailAddresses.mail_base_url()

      normalized ->
        normalized
    end
  end

  defp normalize_base_url(_), do: EmailAddresses.mail_base_url()
end
