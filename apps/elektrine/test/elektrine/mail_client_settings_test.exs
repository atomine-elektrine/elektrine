defmodule Elektrine.MailClientSettingsTest do
  use ExUnit.Case, async: false

  alias Elektrine.MailClientSettings

  setup do
    previous_settings = Application.get_env(:elektrine, :mail_client_settings)

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:elektrine, :mail_client_settings, previous_settings)
      else
        Application.delete_env(:elektrine, :mail_client_settings)
      end
    end)

    :ok
  end

  test "built-in defaults match the public Docker mail ports" do
    Application.delete_env(:elektrine, :mail_client_settings)

    assert %{port: 993, security: :ssl} = MailClientSettings.imap("example.com")
    assert %{port: 995, security: :ssl} = MailClientSettings.pop3("example.com")
    assert %{port: 465, security: :ssl} = MailClientSettings.smtp("example.com")
  end

  test "SSL security label matches email client terminology" do
    assert MailClientSettings.security_label(:ssl) == "SSL/TLS"
  end
end
