defmodule Elektrine.Email.InternalDelivery do
  @moduledoc """
  Durable internal email delivery record.

  Each local recipient gets one row so local mailbox delivery has the same
  inspectable and retryable boundary as external delivery.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Email.Message
  alias Elektrine.Repo

  @statuses ~w(pending delivering delivered failed)
  @recipient_types ~w(to cc bcc)

  schema "internal_email_deliveries" do
    field :user_id, :integer
    field :recipient, :string
    field :recipient_type, :string, default: "to"
    field :params, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :error, :string
    field :last_attempted_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :mailbox, Elektrine.Email.Mailbox
    belongs_to :recipient_mailbox, Elektrine.Email.Mailbox
    belongs_to :sent_message, Message
    belongs_to :delivered_message, Message

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :user_id,
      :mailbox_id,
      :sent_message_id,
      :recipient_mailbox_id,
      :delivered_message_id,
      :recipient,
      :recipient_type,
      :params,
      :status,
      :attempts,
      :error,
      :last_attempted_at,
      :delivered_at
    ])
    |> normalize_recipient()
    |> validate_required([
      :user_id,
      :mailbox_id,
      :sent_message_id,
      :recipient_mailbox_id,
      :recipient,
      :recipient_type,
      :params
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:recipient_type, @recipient_types)
    |> unique_constraint([:sent_message_id, :recipient_type, :recipient],
      name: :internal_email_deliveries_recipient_unique
    )
  end

  def create_or_get(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, delivery} ->
        {:ok, delivery, :created}

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_recipient?(changeset) do
          case get_by_recipient(
                 fetch_attr(attrs, :sent_message_id),
                 fetch_attr(attrs, :recipient_type),
                 fetch_attr(attrs, :recipient)
               ) do
            %__MODULE__{} = delivery -> {:ok, delivery, :existing}
            nil -> {:error, changeset}
          end
        else
          {:error, changeset}
        end
    end
  end

  def get(id) when is_integer(id), do: Repo.get(__MODULE__, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> get(parsed)
      _ -> nil
    end
  end

  def get(_), do: nil

  def list_for_message(sent_message_id) do
    Repo.all(
      from d in __MODULE__,
        where: d.sent_message_id == ^sent_message_id,
        order_by: [asc: d.id]
    )
  end

  def get_by_recipient(sent_message_id, recipient_type, recipient) do
    Repo.one(
      from d in __MODULE__,
        where:
          d.sent_message_id == ^sent_message_id and d.recipient_type == ^recipient_type and
            d.recipient == ^normalize_email(recipient)
    )
  end

  def list_attempts(%__MODULE__{} = delivery) do
    Repo.all(
      from a in Elektrine.Email.InternalDeliveryAttempt,
        where: a.delivery_id == ^delivery.id,
        order_by: [asc: a.attempt, asc: a.id]
    )
  end

  def delivery_summary(sent_message_id) do
    sent_message_id
    |> list_for_message()
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, deliveries} -> {status, length(deliveries)} end)
  end

  def recent_deliveries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    query = from d in __MODULE__, order_by: [desc: d.updated_at], limit: ^limit
    query = if status, do: from(d in query, where: d.status == ^status), else: query
    Repo.all(query)
  end

  def mark_delivering(%__MODULE__{} = delivery) do
    next_attempt = delivery.attempts + 1

    delivery
    |> changeset(%{
      status: "delivering",
      attempts: next_attempt,
      last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> record_attempt(updated, "delivering", %{attempt: next_attempt})
      _ -> :ok
    end)
  end

  def mark_delivered(%__MODULE__{} = delivery, %Message{} = message) do
    delivery
    |> changeset(%{
      status: "delivered",
      delivered_message_id: message.id,
      delivered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        record_attempt(updated, "delivered", %{delivered_message_id: message.id})

      _ ->
        :ok
    end)
  end

  def mark_failed(%__MODULE__{} = delivery, reason) do
    delivery
    |> changeset(%{status: "failed", error: format_reason(reason)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> record_attempt(updated, "failed", %{error: format_reason(reason)})
      _ -> :ok
    end)
  end

  def requeue(%__MODULE__{status: "delivered"}), do: {:error, :already_delivered}

  def requeue(%__MODULE__{} = delivery) do
    delivery
    |> changeset(%{status: "pending", error: nil})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        with {:ok, _job} <- Elektrine.Email.InternalDeliveryWorker.enqueue(updated) do
          {:ok, updated}
        end

      error ->
        error
    end
  end

  defp duplicate_recipient?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:sent_message_id, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp normalize_recipient(changeset) do
    put_change(changeset, :recipient, get_field(changeset, :recipient) |> normalize_email())
  end

  defp record_attempt(delivery, status, metadata) do
    attrs = %{
      delivery_id: delivery.id,
      attempt: delivery.attempts,
      status: status,
      delivered_message_id: metadata[:delivered_message_id] || delivery.delivered_message_id,
      error: metadata[:error] || delivery.error,
      metadata: Map.new(metadata, fn {key, value} -> {to_string(key), value} end),
      attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Elektrine.Email.InternalDeliveryAttempt{}
    |> Elektrine.Email.InternalDeliveryAttempt.changeset(attrs)
    |> Repo.insert()
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_email(nil), do: nil

  defp normalize_email(email) do
    email
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
