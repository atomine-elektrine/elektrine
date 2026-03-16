defmodule Elektrine.SecurityAlertsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.SecurityAlerts

  defmodule FailingMailerAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config), do: {:error, :forced_failure}
    def deliver_many(_emails, _config), do: {:error, :forced_failure}
  end

  test "does not rate limit spoofing alerts when every delivery path fails" do
    previous_mailer_config = Application.get_env(:elektrine, Elektrine.Mailer, [])

    on_exit(fn ->
      Application.put_env(:elektrine, Elektrine.Mailer, previous_mailer_config)
    end)

    Application.put_env(
      :elektrine,
      Elektrine.Mailer,
      Keyword.put(previous_mailer_config, :adapter, FailingMailerAdapter)
    )

    {:ok, user} =
      Accounts.create_user(%{
        username: "spoofalert#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    user =
      user
      |> Ecto.Changeset.change(%{recovery_email: "alerts@example.com"})
      |> Elektrine.Repo.update!()

    if mailbox = Email.get_user_mailbox(user.id) do
      assert {:ok, _deleted_mailbox} = Email.delete_mailbox(mailbox)
    end

    spoofed_address = "spoof#{System.unique_integer([:positive])}@elektrine.com"

    assert {:ok, _alias} =
             Email.create_alias(%{
               alias_email: spoofed_address,
               user_id: user.id,
               enabled: true
             })

    assert {:error, :delivery_failed} =
             SecurityAlerts.send_spoofing_alert(
               spoofed_address,
               "victim@example.net",
               "Test subject"
             )

    assert {:error, :delivery_failed} =
             SecurityAlerts.send_spoofing_alert(
               spoofed_address,
               "victim@example.net",
               "Test subject"
             )
  end
end
