defmodule ElektrineEmailWeb.EmailLive.EmailHelpersTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Email.CustomDomain
  alias Elektrine.Repo
  alias ElektrineEmailWeb.EmailLive.EmailHelpers

  setup do
    previous_email_config = Application.get_env(:elektrine, :email, [])

    on_exit(fn ->
      Application.put_env(:elektrine, :email, previous_email_config)
    end)

    :ok
  end

  test "hides localhost mailbox variants on public instances" do
    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "localhost", "mail.localhost"]
    )

    user = user_fixture(%{username: "maxfield"})

    assert EmailHelpers.mailbox_addresses(%{email: "maxfield@elektrine.com"}, user) == [
             "maxfield@elektrine.com"
           ]
  end

  test "keeps verified custom domains visible on public instances" do
    Application.put_env(:elektrine, :email,
      domain: "elektrine.com",
      supported_domains: ["elektrine.com", "localhost", "mail.localhost"]
    )

    user = user_fixture(%{username: "maxfieldcustom"})

    Repo.insert!(
      CustomDomain.changeset(%CustomDomain{}, %{
        domain: "arblarg.com",
        verification_token: "token-maxfieldcustom",
        status: "verified",
        verified_at: DateTime.utc_now(),
        user_id: user.id
      })
    )

    assert EmailHelpers.mailbox_addresses(%{email: "maxfieldcustom@elektrine.com"}, user) == [
             "maxfieldcustom@elektrine.com",
             "maxfieldcustom@arblarg.com"
           ]
  end

  test "shows localhost mailbox variants on local instances" do
    Application.put_env(:elektrine, :email,
      domain: "localhost",
      supported_domains: ["localhost", "mail.localhost"]
    )

    user = user_fixture(%{username: "devmailbox"})

    assert EmailHelpers.mailbox_addresses(%{email: "devmailbox@localhost"}, user) == [
             "devmailbox@localhost",
             "devmailbox@mail.localhost"
           ]
  end
end
