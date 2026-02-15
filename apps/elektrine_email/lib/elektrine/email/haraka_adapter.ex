defmodule Elektrine.Email.HarakaAdapter do
  @moduledoc """
  Swoosh adapter for Haraka HTTP API server
  """

  use Swoosh.Adapter,
    required_config: [:api_key],
    optional_config: [:base_url, :timeout]

  alias Swoosh.Email

  @default_base_url "https://haraka.elektrine.com"
  @api_path "/api/v1/send"

  @impl true
  def deliver(%Email{} = email, config) do
    base_url = config[:base_url] || @default_base_url
    timeout = config[:timeout] || 30_000

    # Get the appropriate API key based on the from address
    api_key = get_api_key_for_email(email.from, config[:api_key])

    headers = [
      {"Content-Type", "application/json"},
      {"X-API-Key", api_key},
      {"User-Agent", "Elektrine-Swoosh-Haraka/1.0"}
    ]

    body = build_api_body(email)

    request = Finch.build(:post, "#{base_url}#{@api_path}", headers, body)

    case Finch.request(request, Elektrine.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"success" => true, "message_id" => message_id}} ->
            {:ok, %{id: message_id, message_id: message_id}}

          {:ok, %{"success" => false, "error" => error}} ->
            {:error, error}

          {:ok, response} ->
            {:error, "Unexpected Haraka response: #{inspect(response)}"}

          {:error, decode_error} ->
            {:error, "Failed to decode Haraka response: #{inspect(decode_error)}"}
        end

      {:ok, %Finch.Response{status: status_code, body: response_body}} ->
        {:error, "Haraka HTTP API returned status #{status_code}: #{response_body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def deliver_many(emails, config) do
    # Deliver emails one by one via HTTP API
    Enum.map(emails, &deliver(&1, config))
  end

  defp build_api_body(email) do
    # Build the JSON body for Haraka HTTP API
    body = %{
      "from" => format_from(email.from),
      "to" => format_recipients(email.to),
      "subject" => email.subject
    }

    # Add CC if present
    body =
      if email.cc && email.cc != [] do
        Map.put(body, "cc", format_recipients(email.cc))
      else
        body
      end

    # Add BCC if present
    body =
      if email.bcc && email.bcc != [] do
        Map.put(body, "bcc", format_recipients(email.bcc))
      else
        body
      end

    # Add body content
    body =
      cond do
        email.html_body && email.text_body ->
          # Both HTML and plain text
          body
          |> Map.put("html_body", email.html_body)
          |> Map.put("text_body", email.text_body)

        email.html_body ->
          # HTML only
          Map.put(body, "html_body", email.html_body)

        email.text_body ->
          # Plain text only
          Map.put(body, "text_body", email.text_body)

        true ->
          # No body content
          body
      end

    # Add custom headers if present
    body =
      if email.headers && email.headers != %{} do
        Map.put(body, "headers", email.headers)
      else
        body
      end

    Jason.encode!(body)
  end

  defp format_recipients(recipients) when is_list(recipients) do
    recipients
    |> Enum.map(&format_recipient/1)
  end

  defp format_recipient({name, email}) when is_binary(name) and is_binary(email) do
    if name == "" do
      email
    else
      "#{name} <#{email}>"
    end
  end

  defp format_recipient(email) when is_binary(email), do: email

  defp format_from({name, email}) when is_binary(name) and is_binary(email) do
    if name == "" do
      email
    else
      "#{name} <#{email}>"
    end
  end

  defp format_from(email) when is_binary(email), do: email

  # Get the API key (no domain-specific logic needed)
  defp get_api_key_for_email(_from_address, default_key) do
    System.get_env("HARAKA_API_KEY") || default_key
  end
end
