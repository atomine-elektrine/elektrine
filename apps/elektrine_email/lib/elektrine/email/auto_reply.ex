defmodule Elektrine.Email.AutoReply do
  @moduledoc """
  Schema for auto-reply/vacation responder settings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_auto_replies" do
    field :enabled, :boolean, default: false
    field :subject, :string
    field :body, :string
    field :html_body, :string
    field :start_date, :date
    field :end_date, :date
    field :only_contacts, :boolean, default: false
    field :exclude_mailing_lists, :boolean, default: true
    field :reply_once_per_sender, :boolean, default: true

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Creates a changeset for auto-reply settings.
  """
  def changeset(auto_reply, attrs) do
    auto_reply
    |> cast(attrs, [
      :enabled,
      :subject,
      :body,
      :html_body,
      :start_date,
      :end_date,
      :only_contacts,
      :exclude_mailing_lists,
      :reply_once_per_sender,
      :user_id
    ])
    |> validate_required([:body, :user_id])
    |> validate_length(:subject, max: 200)
    |> validate_length(:body, min: 1, max: 10_000)
    |> validate_date_range()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  defp validate_date_range(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    cond do
      is_nil(start_date) || is_nil(end_date) ->
        changeset

      Date.compare(start_date, end_date) == :gt ->
        add_error(changeset, :end_date, "must be after start date")

      true ->
        changeset
    end
  end

  @doc """
  Checks if auto-reply is currently active based on date range.
  """
  def active?(%__MODULE__{enabled: false}), do: false

  def active?(%__MODULE__{enabled: true, start_date: nil, end_date: nil}), do: true

  def active?(%__MODULE__{enabled: true, start_date: start_date, end_date: end_date}) do
    today = Date.utc_today()

    start_ok = is_nil(start_date) || Date.compare(today, start_date) != :lt
    end_ok = is_nil(end_date) || Date.compare(today, end_date) != :gt

    start_ok && end_ok
  end

  @doc """
  Checks if we should send an auto-reply for this message.
  """
  def should_reply?(auto_reply, message, user_id) do
    cond do
      !active?(auto_reply) ->
        false

      # Don't reply to mailing lists if configured
      auto_reply.exclude_mailing_lists && mailing_list?(message) ->
        false

      # Only reply to contacts if configured
      auto_reply.only_contacts && !contact?(message.from, user_id) ->
        false

      # Check if we already replied to this sender
      auto_reply.reply_once_per_sender && already_replied?(message.from, user_id) ->
        false

      # Don't reply to noreply addresses
      noreply?(message.from) ->
        false

      # Don't reply to our own emails
      own_email?(message.from, user_id) ->
        false

      true ->
        true
    end
  end

  defp mailing_list?(message) do
    message.is_newsletter || message.category == "bulk_mail" ||
      (message.metadata && Map.has_key?(message.metadata, "list_id"))
  end

  defp contact?(from_email, user_id) do
    email = extract_email(from_email)
    Elektrine.Email.Contacts.get_contact_by_email(user_id, email) != nil
  end

  defp already_replied?(from_email, user_id) do
    email = extract_email(from_email)
    Elektrine.Email.AutoReplies.has_replied_to?(user_id, email)
  end

  defp noreply?(from_email) do
    email = String.downcase(extract_email(from_email))

    String.contains?(email, "noreply") ||
      String.contains?(email, "no-reply") ||
      String.contains?(email, "donotreply") ||
      String.contains?(email, "mailer-daemon")
  end

  defp own_email?(from_email, user_id) do
    email = String.downcase(extract_email(from_email))
    user = Elektrine.Accounts.get_user!(user_id)
    mailbox = Elektrine.Email.get_user_mailbox(user_id)

    email == String.downcase(user.username <> "@elektrine.com") ||
      email == String.downcase(user.username <> "@z.org") ||
      (mailbox && email == String.downcase(mailbox.email))
  end

  defp extract_email(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  defp extract_email(_), do: ""
end
