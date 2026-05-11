defmodule Elektrine.Email.SystemDelivery do
  @moduledoc """
  Delivers platform-originated email directly into local user mailboxes.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Repo

  require Logger

  @doc """
  Enqueues a system email for every local user mailbox.
  """
  def enqueue_email_to_all_users(attrs, opts \\ []) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    admin_user_id = Keyword.get(opts, :admin_user_id)

    with :ok <- validate_attrs(attrs) do
      attrs
      |> Map.put("admin_user_id", admin_user_id)
      |> Elektrine.Email.SystemDeliveryWorker.new()
      |> Elektrine.JobQueue.insert()
    end
  end

  @doc """
  Delivers a system email immediately to every local user mailbox.

  Returns a summary map with delivered and failed counts. Individual mailbox
  failures are logged and do not abort the whole broadcast.
  """
  def deliver_email_to_all_users(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_attrs(attrs) do
      mailboxes = user_mailboxes()
      from = Map.get(attrs, "from") || system_from_address()
      subject = attrs["subject"]
      text_body = attrs["text_body"]
      html_body = attrs["html_body"]
      admin_user_id = attrs["admin_user_id"]

      summary =
        Enum.reduce(mailboxes, %{delivered: 0, failed: 0, total: length(mailboxes)}, fn mailbox,
                                                                                        acc ->
          case deliver_to_mailbox(mailbox, from, subject, text_body, html_body, admin_user_id) do
            {:ok, _message} ->
              %{acc | delivered: acc.delivered + 1}

            {:error, reason} ->
              Logger.warning(
                "System email delivery failed for mailbox #{mailbox.id}: #{inspect(reason)}"
              )

              %{acc | failed: acc.failed + 1}
          end
        end)

      {:ok, summary}
    end
  end

  def system_from_address do
    "Elektrine System <system@#{Elektrine.Domains.primary_email_domain()}>"
  end

  defp deliver_to_mailbox(mailbox, from, subject, text_body, html_body, admin_user_id) do
    Email.create_message(%{
      message_id: system_message_id(),
      from: from,
      to: mailbox.email,
      subject: subject,
      text_body: text_body,
      html_body: html_body,
      mailbox_id: mailbox.id,
      status: "received",
      category: "inbox",
      metadata: %{
        system_delivery: true,
        admin_user_id: admin_user_id,
        delivered_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    })
  end

  defp user_mailboxes do
    Mailbox
    |> where([m], not is_nil(m.user_id))
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value

  defp validate_attrs(%{"subject" => subject, "text_body" => text_body}) do
    cond do
      !Elektrine.Strings.present?(subject) -> {:error, :missing_subject}
      !Elektrine.Strings.present?(text_body) -> {:error, :missing_body}
      true -> :ok
    end
  end

  defp validate_attrs(_attrs), do: {:error, :missing_required_fields}

  defp system_message_id do
    "system-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}@#{Elektrine.Domains.primary_email_domain()}"
  end
end
