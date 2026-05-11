defmodule Elektrine.Email.SystemDeliveryTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Email

  describe "deliver_system_email_to_all_users/1" do
    test "creates one received message in each user mailbox" do
      user_one = user_fixture("systemone")
      user_two = user_fixture("systemtwo")

      assert {:ok, %{delivered: 2, failed: 0, total: 2}} =
               Email.deliver_system_email_to_all_users(%{
                 subject: "Maintenance notice",
                 text_body: "Elektrine will restart tonight.",
                 admin_user_id: user_one.id
               })

      for user <- [user_one, user_two] do
        [stored_message] = Email.list_user_messages(user.id)
        {:ok, message} = Email.get_user_message(stored_message.id, user.id)

        assert message.status == "received"
        assert message.subject == "Maintenance notice"
        assert message.text_body == "Elektrine will restart tonight."
        assert message.from == Email.system_email_from_address()
        assert message.metadata["system_delivery"] == true
        assert message.metadata["admin_user_id"] == user_one.id
      end
    end

    test "requires subject and body" do
      assert {:error, :missing_subject} =
               Email.deliver_system_email_to_all_users(%{subject: "", text_body: "Body"})

      assert {:error, :missing_body} =
               Email.deliver_system_email_to_all_users(%{subject: "Subject", text_body: ""})
    end
  end

  defp user_fixture(prefix) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        username: "#{prefix}#{unique}",
        password: "password123",
        password_confirmation: "password123"
      })

    user
  end
end
