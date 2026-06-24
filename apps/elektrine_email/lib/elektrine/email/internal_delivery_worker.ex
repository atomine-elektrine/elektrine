defmodule Elektrine.Email.InternalDeliveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :email,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:delivery_id]]

  require Logger

  alias Elektrine.Email
  alias Elektrine.Email.InternalDelivery

  @valid_param_keys %{
    "to" => :to,
    "from" => :from,
    "cc" => :cc,
    "bcc" => :bcc,
    "subject" => :subject,
    "text_body" => :text_body,
    "html_body" => :html_body,
    "reply_to" => :reply_to,
    "message_id" => :message_id,
    "in_reply_to" => :in_reply_to,
    "references" => :references,
    "attachments" => :attachments,
    "headers" => :headers,
    "priority" => :priority,
    "content_type" => :content_type,
    "charset" => :charset,
    "mailbox_id" => :mailbox_id,
    "status" => :status,
    "read" => :read,
    "category" => :category,
    "metadata" => :metadata,
    "is_newsletter" => :is_newsletter,
    "is_receipt" => :is_receipt,
    "is_notification" => :is_notification
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    case load_delivery(delivery_id) do
      nil ->
        :ok

      %InternalDelivery{status: "delivered"} ->
        :ok

      %InternalDelivery{} = delivery ->
        case deliver_now(delivery) do
          {:ok, _message_or_delivery} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def enqueue(%InternalDelivery{} = delivery) do
    %{"delivery_id" => delivery.id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def deliver_now(%InternalDelivery{status: "delivered"} = delivery), do: {:ok, delivery}

  def deliver_now(%InternalDelivery{} = delivery) do
    with {:ok, delivering} <- InternalDelivery.mark_delivering(delivery),
         {:ok, message} <- Email.create_message(atomize_keys(delivering.params)),
         {:ok, _delivered} <- InternalDelivery.mark_delivered(delivering, message) do
      {:ok, message}
    else
      {:error, reason} ->
        _ = InternalDelivery.mark_failed(delivery, reason)
        Logger.error("Internal email delivery #{delivery.id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_delivery(id) when is_integer(id), do: InternalDelivery.get(id)

  defp load_delivery(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> InternalDelivery.get(parsed)
      _ -> nil
    end
  end

  defp load_delivery(_), do: nil

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        case Map.fetch(@valid_param_keys, key) do
          {:ok, atom_key} -> {atom_key, atomize_keys(value)}
          :error -> {key, atomize_keys(value)}
        end

      {key, value} when is_atom(key) ->
        {key, atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value
end
