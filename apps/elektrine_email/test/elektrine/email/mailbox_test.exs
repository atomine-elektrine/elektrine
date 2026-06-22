defmodule Elektrine.Email.MailboxTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Domains
  alias Elektrine.Email.Mailbox

  describe "changeset/2" do
    test "rejects reserved operational and certificate-validation usernames" do
      for username <- ~w(abuse postmaster ssladmin ssladministrator sysadmin noc payments dmca) do
        changeset =
          Mailbox.changeset(%Mailbox{}, %{
            email: "#{username}@#{Domains.primary_email_domain()}",
            username: username,
            user_id: 1
          })

        refute changeset.valid?, "#{username}@ should be reserved"
        assert "this username is reserved and cannot be used" in errors_on(changeset).username
      end
    end
  end
end
