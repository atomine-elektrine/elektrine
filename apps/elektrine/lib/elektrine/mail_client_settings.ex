defmodule Elektrine.MailClientSettings do
  @moduledoc """
  Resolves the client-facing mail host, port, and transport settings.
  """

  alias Elektrine.Domains
  alias Elektrine.RuntimeEnv

  @default_settings [
    imap: [port: 993, security: :ssl],
    pop3: [port: 995, security: :ssl],
    smtp: [port: 465, security: :ssl]
  ]

  def imap(domain \\ Domains.primary_email_domain()), do: build(:imap, domain)
  def pop3(domain \\ Domains.primary_email_domain()), do: build(:pop3, domain)
  def smtp(domain \\ Domains.primary_email_domain()), do: build(:smtp, domain)

  def socket_type(%{security: security}), do: socket_type(security)
  def socket_type(:ssl), do: "SSL"
  def socket_type(:starttls), do: "STARTTLS"
  def socket_type(:plain), do: "plain"

  def security_label(%{security: security}), do: security_label(security)
  def security_label(:ssl), do: "TLS"
  def security_label(:starttls), do: "STARTTLS"
  def security_label(:plain), do: "plain text"

  def ssl?(%{security: security}), do: ssl?(security)
  def ssl?(:ssl), do: true
  def ssl?(:starttls), do: false
  def ssl?(:plain), do: false

  def starttls?(%{security: security}), do: starttls?(security)
  def starttls?(:starttls), do: true
  def starttls?(:ssl), do: false
  def starttls?(:plain), do: false

  def host(protocol, domain \\ Domains.primary_email_domain())
      when protocol in [:imap, :pop3, :smtp] do
    env_host(protocol) || present_env("MAIL_SERVICE_HOST") ||
      "#{protocol}.#{String.downcase(domain)}"
  end

  defp build(protocol, domain) do
    default_settings = Keyword.fetch!(@default_settings, protocol)
    configured_settings = configured_settings(protocol)

    %{
      protocol: protocol,
      host: host(protocol, domain),
      port: Keyword.get(configured_settings, :port, Keyword.fetch!(default_settings, :port)),
      security:
        configured_settings
        |> Keyword.get(:security, Keyword.fetch!(default_settings, :security))
        |> normalize_security()
    }
  end

  defp configured_settings(protocol) do
    client_settings = Application.get_env(:elektrine, :mail_client_settings, [])

    cond do
      Keyword.keyword?(client_settings) and Keyword.has_key?(client_settings, protocol) ->
        Keyword.get(client_settings, protocol, [])

      RuntimeEnv.environment() == :dev ->
        listener_settings(protocol)

      true ->
        []
    end
  end

  defp listener_settings(:imap) do
    if Application.get_env(:elektrine, :imaps_enabled, false) do
      [port: Application.get_env(:elektrine, :imaps_port, 2993), security: :ssl]
    else
      [port: Application.get_env(:elektrine, :imap_port, 2143), security: :plain]
    end
  end

  defp listener_settings(:pop3) do
    if Application.get_env(:elektrine, :pop3s_enabled, false) do
      [port: Application.get_env(:elektrine, :pop3s_port, 2995), security: :ssl]
    else
      [port: Application.get_env(:elektrine, :pop3_port, 2110), security: :plain]
    end
  end

  defp listener_settings(:smtp) do
    [port: Application.get_env(:elektrine, :smtp_port, 2587), security: :plain]
  end

  defp env_host(:imap), do: present_env("IMAP_HOST")
  defp env_host(:pop3), do: present_env("POP_HOST") || present_env("POP3_HOST")
  defp env_host(:smtp), do: present_env("SMTP_HOST")

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp normalize_security(:ssl), do: :ssl
  defp normalize_security(:starttls), do: :starttls
  defp normalize_security(:plain), do: :plain

  defp normalize_security(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "ssl" -> :ssl
      "tls" -> :ssl
      "starttls" -> :starttls
      _ -> :plain
    end
  end

  defp normalize_security(_value), do: :plain
end
