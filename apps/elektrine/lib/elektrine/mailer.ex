defmodule Elektrine.Mailer do
  use Swoosh.Mailer, otp_app: :elektrine

  @doc """
  Queues the email for delivery on the `:email` Oban queue so transient
  mail-server failures are retried instead of dropped.

  Returns `{:ok, %Oban.Job{}}` once the email is durably queued. Attachments
  are not supported on this path; use `deliver/1` for emails that carry them.
  """
  def deliver_later(%Swoosh.Email{attachments: [_ | _]}) do
    raise ArgumentError, "deliver_later/1 does not support attachments"
  end

  def deliver_later(%Swoosh.Email{} = email) do
    Elektrine.Mailer.DeliveryWorker.enqueue(email)
  end
end
