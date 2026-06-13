defmodule Elektrine.Email.HarakaAdapter do
  @moduledoc """
  Swoosh adapter for the Haraka HTTP API server.

  Translates `Swoosh.Email` structs into `Elektrine.Email.HarakaClient` params
  and delegates delivery to it, so transactional mail shares the same wire
  format (RFC 2047 header encoding, UTF-8 sanitization, attachment handling,
  internal origin signing) as user-composed mail.
  """

  use Swoosh.Adapter,
    required_config: [:api_key],
    optional_config: [:base_url, :timeout]

  alias Elektrine.Email.HarakaClient
  alias Elektrine.Email.InternalOrigin
  alias Swoosh.Email

  @impl true
  def deliver(%Email{} = email, _config) do
    email
    |> to_client_params()
    |> HarakaClient.send_email()
  end

  @impl true
  def deliver_many(emails, config) do
    # Deliver emails one by one via HTTP API
    Enum.map(emails, &deliver(&1, config))
  end

  @doc false
  def build_api_body(%Email{} = email) do
    email
    |> to_client_params()
    |> InternalOrigin.sign_params()
    |> HarakaClient.build_api_body()
  end

  @doc false
  def to_client_params(%Email{} = email) do
    params = %{
      from: format_address(email.from),
      to: Enum.map(email.to || [], &format_address/1),
      subject: email.subject,
      text_body: email.text_body,
      html_body: email.html_body,
      headers: email.headers || %{}
    }

    params
    |> maybe_put(:cc, join_addresses(email.cc))
    |> maybe_put(:bcc, join_addresses(email.bcc))
    |> maybe_put(:reply_to, format_address(email.reply_to))
    |> maybe_put(:attachments, attachment_params(email.attachments))
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, []), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  # HarakaClient expects cc/bcc as comma-separated strings.
  defp join_addresses(nil), do: nil
  defp join_addresses([]), do: nil

  defp join_addresses(addresses) when is_list(addresses) do
    Enum.map_join(addresses, ", ", &format_address/1)
  end

  defp format_address(nil), do: nil
  defp format_address({"", address}) when is_binary(address), do: address

  defp format_address({name, address}) when is_binary(name) and is_binary(address) do
    "#{name} <#{address}>"
  end

  defp format_address(address) when is_binary(address), do: address

  defp attachment_params(nil), do: []

  defp attachment_params(attachments) when is_list(attachments) do
    Enum.map(attachments, fn %Swoosh.Attachment{} = attachment ->
      base = %{
        "filename" => attachment.filename,
        "content_type" => attachment.content_type,
        "data" => Swoosh.Attachment.get_content(attachment)
      }

      case attachment.cid do
        nil -> base
        cid -> Map.put(base, "content_id", cid)
      end
    end)
  end
end
