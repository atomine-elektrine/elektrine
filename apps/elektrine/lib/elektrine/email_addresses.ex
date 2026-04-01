defmodule Elektrine.EmailAddresses do
  @moduledoc """
  Helpers for rendering instance and user email addresses from configured domains.
  """

  alias Elektrine.Domains
  alias Elektrine.MailClientSettings

  def local(local_part) when is_binary(local_part) do
    "#{String.trim(local_part)}@#{Domains.primary_email_domain()}"
  end

  def mailto(local_part) when is_binary(local_part) do
    "mailto:" <> local(local_part)
  end

  def uid(value) do
    "#{value |> to_string() |> String.trim()}@#{Domains.primary_email_domain()}"
  end

  def message_id(value) do
    "<#{uid(value)}>"
  end

  def list_id(value) do
    "<#{value |> to_string() |> String.trim()}.#{Domains.primary_email_domain()}>"
  end

  def primary_for_user(%{username: username} = user) when is_binary(username) do
    domain =
      case Map.get(user, :preferred_email_domain) do
        value when is_binary(value) ->
          trimmed = String.trim(value)

          if trimmed == "" do
            Domains.default_user_handle_domain()
          else
            trimmed
          end

        _ ->
          Domains.default_user_handle_domain()
      end

    "#{String.trim(username)}@#{domain}"
  end

  def primary_for_user(_), do: nil

  def imap_host, do: MailClientSettings.host(:imap)
  def pop_host, do: MailClientSettings.host(:pop3)
  def smtp_host, do: MailClientSettings.host(:smtp)
  def mail_base_url, do: Domains.mail_base_url()
end
