defmodule Elektrine.Accounts.AuthenticationCustomDomainTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts.Authentication
  alias Elektrine.AccountsFixtures
  alias Elektrine.CustomDomains
  alias Elektrine.Email

  test "authenticate_with_app_password/2 accepts configured custom-domain addresses" do
    user = AccountsFixtures.user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    {:ok, domain} = CustomDomains.add_domain(user.id, "auth-custom-domain.com")

    assert {:ok, _address} = CustomDomains.add_address(domain, "imapbox", mailbox.id)

    assert {:ok, app_password} =
             Authentication.create_app_password(user.id, %{name: "Mail Client"})

    assert {:ok, authed_user} =
             Authentication.authenticate_with_app_password(
               "imapbox@auth-custom-domain.com",
               app_password.token
             )

    assert authed_user.id == user.id
  end

  test "authenticate_with_app_password/2 supports custom-domain catch-all mailbox" do
    user = AccountsFixtures.user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    {:ok, domain} = CustomDomains.add_domain(user.id, "auth-catchall-domain.com")

    assert {:ok, _updated} = CustomDomains.configure_catch_all(domain, mailbox.id, true)
    assert {:ok, app_password} = Authentication.create_app_password(user.id, %{name: "Catch-all"})

    assert {:ok, authed_user} =
             Authentication.authenticate_with_app_password(
               "anything@auth-catchall-domain.com",
               app_password.token
             )

    assert authed_user.id == user.id
  end
end
