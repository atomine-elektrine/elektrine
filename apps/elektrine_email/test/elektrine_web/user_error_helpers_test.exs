defmodule ElektrineWeb.UserErrorHelpersTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Domains
  alias Elektrine.Email
  alias Elektrine.Email.Alias
  alias ElektrineWeb.UserErrorHelpers

  describe "join_changeset_errors/2" do
    test "returns friendly alias conflicts without field names" do
      user = user_fixture()
      mailbox = Email.get_user_mailbox(user.id)

      changeset =
        Alias.changeset(%Alias{}, %{
          alias_email: mailbox.email,
          user_id: user.id
        })

      assert UserErrorHelpers.join_changeset_errors(changeset) ==
               "That email address is already in use."
    end

    test "normalizes short alias validation copy" do
      user = user_fixture()

      changeset =
        Alias.changeset(%Alias{}, %{
          alias_email: "abc@#{Domains.primary_email_domain()}",
          user_id: user.id
        })

      assert UserErrorHelpers.join_changeset_errors(changeset) ==
               "Use at least 4 letters or numbers before the @."
    end
  end

  describe "reason_message/2" do
    test "falls back instead of leaking opaque reasons" do
      assert UserErrorHelpers.reason_message(
               :timeout,
               "Could not verify the custom domain right now."
             ) == "Could not verify the custom domain right now."
    end
  end
end
