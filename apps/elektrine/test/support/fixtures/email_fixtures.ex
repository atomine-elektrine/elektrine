defmodule Elektrine.EmailFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Elektrine.Email` context.
  """

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Repo

  def unique_email, do: "user#{System.unique_integer([:positive])}@elektrine.com"

  def valid_mailbox_attributes(attrs \\ %{}) do
    email = attrs[:email] || unique_email()
    username = email |> String.split("@") |> List.first()

    Enum.into(attrs, %{
      email: email,
      username: username,
      user_id: attrs[:user_id]
    })
  end

  def mailbox_fixture(attrs \\ %{}) do
    attrs = valid_mailbox_attributes(attrs)
    mailbox_struct = :erlang.apply(Mailbox, :__struct__, [])

    {:ok, mailbox} =
      mailbox_struct
      |> Mailbox.changeset(attrs)
      |> Repo.insert()

    mailbox
  end

  def message_fixture(attrs \\ %{}) do
    defaults = %{
      from: "sender@example.com",
      to: "recipient@elektrine.com",
      subject: "Test Subject #{System.unique_integer([:positive])}",
      text_body: "Test body content",
      html_body: "<p>Test body content</p>",
      message_id: "test-#{System.unique_integer([:positive])}@example.com",
      status: "received",
      read: false,
      spam: false,
      archived: false,
      deleted: false
    }

    attrs = Map.merge(defaults, attrs)

    {:ok, message} = Email.MailboxAdapter.create_message(attrs)
    message
  end
end
