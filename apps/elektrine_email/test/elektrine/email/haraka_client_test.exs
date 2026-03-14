defmodule Elektrine.Email.HarakaClientTest do
  use ExUnit.Case, async: false

  alias Elektrine.Email.HarakaClient

  defmodule MockHarakaHTTPClient do
    def request(method, url, headers, body, _opts) do
      request = %{method: method, url: url, headers: headers, body: body}
      Process.put({__MODULE__, :requests}, [request | requests()])

      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!(%{"success" => true, "message_id" => "queued-message"})
       }}
    end

    def clear_requests, do: Process.put({__MODULE__, :requests}, [])
    def requests, do: Process.get({__MODULE__, :requests}, [])
  end

  setup do
    previous_email_config = Application.get_env(:elektrine, :email, [])
    previous_mailer_config = Application.get_env(:elektrine, Elektrine.Mailer, [])
    previous_haraka_base_url = System.get_env("HARAKA_BASE_URL")
    previous_haraka_api_key = System.get_env("HARAKA_API_KEY")
    previous_haraka_http_api_key = System.get_env("HARAKA_HTTP_API_KEY")
    previous_haraka_outbound_api_key = System.get_env("HARAKA_OUTBOUND_API_KEY")

    Application.put_env(
      :elektrine,
      :email,
      Keyword.merge(previous_email_config, haraka_http_client: MockHarakaHTTPClient)
    )

    MockHarakaHTTPClient.clear_requests()
    System.delete_env("HARAKA_BASE_URL")
    System.delete_env("HARAKA_API_KEY")
    System.delete_env("HARAKA_HTTP_API_KEY")
    System.delete_env("HARAKA_OUTBOUND_API_KEY")

    on_exit(fn ->
      Application.put_env(:elektrine, :email, previous_email_config)
      Application.put_env(:elektrine, Elektrine.Mailer, previous_mailer_config)
      restore_env("HARAKA_BASE_URL", previous_haraka_base_url)
      restore_env("HARAKA_API_KEY", previous_haraka_api_key)
      restore_env("HARAKA_HTTP_API_KEY", previous_haraka_http_api_key)
      restore_env("HARAKA_OUTBOUND_API_KEY", previous_haraka_outbound_api_key)
    end)

    :ok
  end

  test "uses the configured mailer base_url when HARAKA_BASE_URL is unset" do
    Application.put_env(:elektrine, Elektrine.Mailer,
      api_key: "mailer-api-key",
      base_url: "https://mail.elektrine.test"
    )

    assert {:ok, %{message_id: "queued-message"}} =
             HarakaClient.send_email(%{
               from: "sender@elektrine.com",
               to: "dest@example.net",
               subject: "Test",
               text_body: "Hello"
             })

    [request] = MockHarakaHTTPClient.requests()
    assert request.method == :post
    assert request.url == "https://mail.elektrine.test/api/v1/send"

    assert Enum.any?(request.headers, fn {key, value} ->
             key == "X-API-Key" and value == "mailer-api-key"
           end)
  end

  test "falls back to the mail subdomain default when no base_url is configured" do
    Application.put_env(:elektrine, Elektrine.Mailer, api_key: "mailer-api-key")

    assert {:ok, %{message_id: "queued-message"}} =
             HarakaClient.send_email(%{
               from: "sender@elektrine.com",
               to: "dest@example.net",
               subject: "Test",
               text_body: "Hello"
             })

    [request] = MockHarakaHTTPClient.requests()
    assert request.url == "https://mail.elektrine.com/api/v1/send"
  end

  test "uses HARAKA_HTTP_API_KEY as the outbound API key alias" do
    System.put_env("HARAKA_HTTP_API_KEY", "http-directional-key")
    Application.put_env(:elektrine, Elektrine.Mailer, base_url: "https://mail.elektrine.test")

    assert {:ok, %{message_id: "queued-message"}} =
             HarakaClient.send_email(%{
               from: "sender@elektrine.com",
               to: "dest@example.net",
               subject: "Test",
               text_body: "Hello"
             })

    [request] = MockHarakaHTTPClient.requests()

    assert Enum.any?(request.headers, fn {key, value} ->
             key == "X-API-Key" and value == "http-directional-key"
           end)
  end

  test "rewrites the legacy haraka host to the mail subdomain" do
    Application.put_env(:elektrine, Elektrine.Mailer,
      api_key: "mailer-api-key",
      base_url: "https://haraka.elektrine.com"
    )

    assert {:ok, %{message_id: "queued-message"}} =
             HarakaClient.send_email(%{
               from: "sender@elektrine.com",
               to: "dest@example.net",
               subject: "Test",
               text_body: "Hello"
             })

    [request] = MockHarakaHTTPClient.requests()
    assert request.url == "https://mail.elektrine.com/api/v1/send"
  end

  test "base64-encodes raw attachment binaries before JSON encoding" do
    attachment_data = <<255, 241, 80, 64, 12, 127, 252, 1, 64, 34, 128, 163>>

    Application.put_env(:elektrine, Elektrine.Mailer,
      api_key: "mailer-api-key",
      base_url: "https://mail.elektrine.test"
    )

    assert {:ok, %{message_id: "queued-message"}} =
             HarakaClient.send_email(%{
               from: "sender@elektrine.com",
               to: "dest@example.net",
               subject: "Attachment test",
               text_body: "Hello",
               attachments: %{
                 "0" => %{
                   "filename" => "voice-note.m4a",
                   "content_type" => "audio/mp4",
                   "data" => attachment_data
                 }
               }
             })

    [request] = MockHarakaHTTPClient.requests()
    decoded_request = Jason.decode!(request.body)
    [attachment] = decoded_request["attachments"]

    assert attachment["encoding"] == "base64"
    assert attachment["filename"] == "voice-note.m4a"
    assert Base.decode64!(attachment["data"]) == attachment_data
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
