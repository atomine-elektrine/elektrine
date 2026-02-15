defmodule Elektrine.Email.AutoReplies do
  @moduledoc """
  Context module for managing auto-reply/vacation responder settings.
  """
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.AutoReply

  require Logger

  @doc """
  Gets the auto-reply settings for a user.
  Creates default settings if none exist.
  """
  def get_auto_reply(user_id) do
    case Repo.get_by(AutoReply, user_id: user_id) do
      nil ->
        # Return a new struct with defaults (not persisted)
        %AutoReply{user_id: user_id, enabled: false, body: ""}

      auto_reply ->
        auto_reply
    end
  end

  @doc """
  Gets the auto-reply settings for a user, returns nil if not set.
  """
  def get_auto_reply!(user_id) do
    Repo.get_by(AutoReply, user_id: user_id)
  end

  @doc """
  Creates or updates auto-reply settings for a user.
  """
  def upsert_auto_reply(user_id, attrs) do
    case Repo.get_by(AutoReply, user_id: user_id) do
      nil ->
        %AutoReply{}
        |> AutoReply.changeset(Map.put(attrs, :user_id, user_id))
        |> Repo.insert()

      existing ->
        existing
        |> AutoReply.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Enables auto-reply for a user.
  """
  def enable_auto_reply(user_id) do
    case Repo.get_by(AutoReply, user_id: user_id) do
      nil ->
        {:error, :not_configured}

      auto_reply ->
        auto_reply
        |> AutoReply.changeset(%{enabled: true})
        |> Repo.update()
    end
  end

  @doc """
  Disables auto-reply for a user.
  """
  def disable_auto_reply(user_id) do
    case Repo.get_by(AutoReply, user_id: user_id) do
      nil ->
        {:ok, nil}

      auto_reply ->
        auto_reply
        |> AutoReply.changeset(%{enabled: false})
        |> Repo.update()
    end
  end

  @doc """
  Deletes auto-reply settings for a user.
  """
  def delete_auto_reply(user_id) do
    case Repo.get_by(AutoReply, user_id: user_id) do
      nil -> {:ok, nil}
      auto_reply -> Repo.delete(auto_reply)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking auto-reply changes.
  """
  def change_auto_reply(%AutoReply{} = auto_reply, attrs \\ %{}) do
    AutoReply.changeset(auto_reply, attrs)
  end

  @doc """
  Checks if we've already sent an auto-reply to this sender.
  """
  def has_replied_to?(user_id, sender_email) do
    sender_email = String.downcase(String.trim(sender_email))

    query =
      from l in "email_auto_reply_log",
        where: l.user_id == ^user_id and l.sender_email == ^sender_email,
        select: count(l.id)

    Repo.one(query) > 0
  end

  @doc """
  Records that we sent an auto-reply to a sender.
  """
  def record_auto_reply(user_id, sender_email) do
    sender_email = String.downcase(String.trim(sender_email))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "email_auto_reply_log",
      [%{user_id: user_id, sender_email: sender_email, sent_at: now}],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Clears the auto-reply log for a user (e.g., when starting a new vacation).
  """
  def clear_auto_reply_log(user_id) do
    from(l in "email_auto_reply_log", where: l.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Processes an incoming message and sends auto-reply if appropriate.
  """
  def process_auto_reply(message, user_id) do
    auto_reply = get_auto_reply!(user_id)

    if auto_reply && AutoReply.should_reply?(auto_reply, message, user_id) do
      send_auto_reply(auto_reply, message, user_id)
    else
      :skip
    end
  end

  defp send_auto_reply(auto_reply, message, user_id) do
    # Get user's mailbox for sending
    mailbox = Elektrine.Email.get_user_mailbox(user_id)

    if mailbox do
      subject =
        auto_reply.subject ||
          "Re: #{message.subject || "Auto-Reply"}"

      email_attrs = %{
        from: mailbox.email,
        to: extract_email(message.from),
        subject: subject,
        text_body: auto_reply.body,
        html_body: auto_reply.html_body || auto_reply.body
      }

      case Elektrine.Email.Sender.send_email(user_id, email_attrs) do
        {:ok, _sent} ->
          # Record that we replied to this sender
          record_auto_reply(user_id, message.from)
          Logger.info("Sent auto-reply to #{message.from} for user #{user_id}")
          :sent

        {:error, reason} ->
          Logger.error("Failed to send auto-reply: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.warning("No mailbox found for user #{user_id}, skipping auto-reply")
      :skip
    end
  end

  defp extract_email(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  defp extract_email(_), do: ""
end
