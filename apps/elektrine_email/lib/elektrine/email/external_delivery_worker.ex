defmodule Elektrine.Email.ExternalDeliveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :email,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:delivery_id]]

  require Logger

  alias Elektrine.Email.ExternalDelivery
  alias Elektrine.Email.ExternalDeliveryControl
  alias Elektrine.Email.ExternalDomainThrottle
  alias Elektrine.Email.Sender
  alias Elektrine.Email.Suppressions

  @valid_param_keys ~w(
    to from cc bcc subject text_body html_body reply_to message_id in_reply_to
    references attachments headers priority content_type charset list_id
  )

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}} = job) do
    case load_delivery(delivery_id) do
      nil ->
        :ok

      %ExternalDelivery{status: status}
      when status in ["sent", "bounced", "complained", "suppressed", "paused"] ->
        :ok

      %ExternalDelivery{} = delivery ->
        if ExternalDeliveryControl.paused?(delivery.user_id, delivery.domain) do
          _ = ExternalDelivery.mark_paused(delivery, "paused by admin control")
          :ok
        else
          case ExternalDomainThrottle.check(delivery.domain) do
            :ok -> deliver(delivery, job)
            {:snooze, seconds} -> {:snooze, seconds}
          end
        end
    end
  end

  def enqueue(%ExternalDelivery{} = delivery) do
    %{"delivery_id" => delivery.id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  defp deliver(%ExternalDelivery{} = delivery, %Oban.Job{} = job) do
    with {:ok, sending_delivery} <- ExternalDelivery.mark_sending(delivery),
         {:ok, response} <- Sender.deliver_external_params(atomize_keys(sending_delivery.params)),
         {:ok, _sent_delivery} <- ExternalDelivery.mark_sent(sending_delivery, response) do
      ExternalDomainThrottle.record(sending_delivery.domain)
      :ok
    else
      {:error, reason} ->
        handle_delivery_failure(delivery, reason, job)
    end
  end

  defp handle_delivery_failure(%ExternalDelivery{} = delivery, reason, %Oban.Job{} = job) do
    case ExternalDelivery.mark_failed(delivery, reason) do
      {:ok, %ExternalDelivery{status: "deferred"}} when job.attempt < job.max_attempts ->
        {:snooze, ExternalDomainThrottle.retry_backoff_seconds(delivery.domain, job.attempt)}

      {:ok, %ExternalDelivery{status: status} = updated}
      when status in ["bounced", "complained"] ->
        _ =
          Suppressions.suppress_recipient(updated.user_id, updated.recipient,
            reason: status,
            source: "external_delivery",
            metadata: %{"delivery_id" => updated.id, "trace_id" => updated.trace_id}
          )

        :ok

      {:ok, %ExternalDelivery{status: "deferred"}} ->
        Logger.error(
          "External email delivery #{delivery.id} exhausted retries: #{inspect(reason)}"
        )

        {:error, reason}

      _ ->
        Logger.error("External email delivery #{delivery.id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_delivery(id) when is_integer(id), do: ExternalDelivery.get(id)

  defp load_delivery(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> ExternalDelivery.get(parsed)
      _ -> nil
    end
  end

  defp load_delivery(_), do: nil

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        if key in @valid_param_keys do
          {String.to_existing_atom(key), atomize_keys(value)}
        else
          {key, atomize_keys(value)}
        end

      {key, value} when is_atom(key) ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value
end
