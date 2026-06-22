defmodule Elektrine.Email.ExternalDelivery do
  @moduledoc """
  Durable external email delivery record.

  Each external recipient gets one delivery row. This gives SMTP/API submission
  a stable boundary before provider delivery and prevents duplicate provider
  sends for repeated client submissions of the same message.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Email.Message
  alias Elektrine.Email.Suppressions
  alias Elektrine.Repo

  @statuses ~w(pending sending sent deferred bounced complained suppressed failed paused)
  @recipient_types ~w(to cc bcc)

  schema "external_email_deliveries" do
    field :user_id, :integer
    field :envelope_from, :string
    field :to, {:array, :string}, default: []
    field :cc, {:array, :string}, default: []
    field :bcc, {:array, :string}, default: []
    field :recipient, :string
    field :recipient_type, :string, default: "to"
    field :domain, :string
    field :trace_id, :string
    field :params, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :provider, :string
    field :provider_message_id, :string
    field :response_code, :string
    field :error, :string
    field :last_attempted_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :mailbox, Elektrine.Email.Mailbox
    belongs_to :sent_message, Message

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :user_id,
      :mailbox_id,
      :sent_message_id,
      :envelope_from,
      :to,
      :cc,
      :bcc,
      :recipient,
      :recipient_type,
      :domain,
      :trace_id,
      :params,
      :status,
      :attempts,
      :provider,
      :provider_message_id,
      :response_code,
      :error,
      :last_attempted_at,
      :delivered_at
    ])
    |> normalize_recipient_fields()
    |> validate_required([
      :user_id,
      :mailbox_id,
      :sent_message_id,
      :envelope_from,
      :recipient,
      :recipient_type,
      :domain,
      :trace_id,
      :params
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:recipient_type, @recipient_types)
    |> validate_recipient_present()
    |> unique_constraint([:sent_message_id, :recipient_type, :recipient],
      name: :external_email_deliveries_recipient_unique
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

  def get_by_sent_message_id(sent_message_id) do
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

  def list_for_message(sent_message_id), do: get_by_sent_message_id(sent_message_id)

  def list_attempts(%__MODULE__{} = delivery) do
    Repo.all(
      from a in Elektrine.Email.ExternalDeliveryAttempt,
        where: a.delivery_id == ^delivery.id,
        order_by: [asc: a.attempt, asc: a.id]
    )
  end

  def trace(trace_id) when is_binary(trace_id) do
    delivery = Repo.one(from d in __MODULE__, where: d.trace_id == ^trace_id)

    case delivery do
      %__MODULE__{} -> %{delivery: delivery, attempts: list_attempts(delivery)}
      nil -> nil
    end
  end

  def find_for_signal(attrs) when is_map(attrs) do
    trace_id = fetch_attr(attrs, :trace_id)
    provider_message_id = fetch_attr(attrs, :provider_message_id)
    message_id = fetch_attr(attrs, :message_id)
    recipient = fetch_attr(attrs, :recipient) |> normalize_email()

    cond do
      is_binary(trace_id) and trace_id != "" ->
        delivery_by_trace(trace_id)

      is_binary(provider_message_id) and provider_message_id != "" ->
        Repo.one(from d in __MODULE__, where: d.provider_message_id == ^provider_message_id)

      is_binary(message_id) and is_binary(recipient) ->
        find_by_message_and_recipient(message_id, recipient)

      true ->
        nil
    end
  end

  def find_by_message_and_recipient(message_id, recipient) do
    candidates = message_id_lookup_candidates(message_id)
    recipient = normalize_email(recipient)

    Repo.one(
      from d in __MODULE__,
        join: m in assoc(d, :sent_message),
        where: m.message_id in ^candidates and d.recipient == ^recipient,
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  def delivery_summary(sent_message_id) do
    sent_message_id
    |> list_for_message()
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, deliveries} -> {status, length(deliveries)} end)
  end

  def operational_metrics(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -86_400, :second))

    stuck_cutoff =
      Keyword.get(opts, :stuck_cutoff, DateTime.add(DateTime.utc_now(), -900, :second))

    totals =
      Repo.all(
        from d in __MODULE__,
          where: d.inserted_at >= ^since,
          group_by: d.status,
          select: {d.status, count(d.id)}
      )
      |> Map.new()

    failed_domains =
      Repo.all(
        from d in __MODULE__,
          where:
            d.inserted_at >= ^since and
              d.status in ["failed", "deferred", "bounced", "complained"],
          group_by: d.domain,
          order_by: [desc: count(d.id)],
          limit: 20,
          select: {d.domain, count(d.id)}
      )

    stuck =
      Repo.aggregate(
        from(d in __MODULE__,
          where: d.status in ["pending", "sending", "deferred"] and d.updated_at < ^stuck_cutoff
        ),
        :count,
        :id
      )

    total = Enum.reduce(totals, 0, fn {_status, count}, acc -> acc + count end)

    %{
      since: since,
      totals: totals,
      queue_depth: Map.get(totals, "pending", 0) + Map.get(totals, "deferred", 0),
      stuck_count: stuck,
      failed_domains: failed_domains,
      bounce_rate: ratio(Map.get(totals, "bounced", 0), total),
      complaint_rate: ratio(Map.get(totals, "complained", 0), total)
    }
  end

  def recent_deliveries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)
    domain = Keyword.get(opts, :domain)

    query = from d in __MODULE__, order_by: [desc: d.updated_at], limit: ^limit
    query = if status, do: from(d in query, where: d.status == ^status), else: query
    query = if domain, do: from(d in query, where: d.domain == ^domain), else: query
    Repo.all(query)
  end

  def requeue_stuck(opts \\ []) do
    cutoff = Keyword.get(opts, :cutoff, DateTime.add(DateTime.utc_now(), -1800, :second))

    from(d in __MODULE__,
      where: d.status == "sending" and d.updated_at < ^cutoff
    )
    |> Repo.all()
    |> Enum.map(&requeue/1)
  end

  def prune_attempts_older_than(cutoff) do
    from(a in Elektrine.Email.ExternalDeliveryAttempt, where: a.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  def list_for_domain(domain, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    status = Keyword.get(opts, :status)
    domain = domain |> to_string() |> String.downcase()

    query =
      from d in __MODULE__,
        where: d.domain == ^domain,
        order_by: [desc: d.inserted_at],
        limit: ^limit

    query = if status, do: from(d in query, where: d.status == ^status), else: query
    Repo.all(query)
  end

  def mark_sending(%__MODULE__{} = delivery) do
    next_attempt = delivery.attempts + 1

    delivery
    |> changeset(%{
      status: "sending",
      attempts: next_attempt,
      last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> record_attempt(updated, "sending", %{attempt: next_attempt})
      _ -> :ok
    end)
  end

  def mark_sent(%__MODULE__{} = delivery, response) do
    provider_message_id = response_message_id(response)

    delivery
    |> changeset(%{
      status: "sent",
      provider: provider_name(),
      provider_message_id: provider_message_id,
      response_code: response_code(response),
      delivered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        record_attempt(updated, "sent", %{provider_message_id: provider_message_id})

      _ ->
        :ok
    end)
  end

  def mark_failed(%__MODULE__{} = delivery, reason) do
    status = classify_failure_status(reason)

    delivery
    |> changeset(%{
      status: status,
      error: format_reason(reason),
      response_code: response_code(reason)
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        if status in ["bounced", "complained"], do: suppress_delivery_recipient(updated, status)
        record_attempt(updated, status, %{error: format_reason(reason)})

      _ ->
        :ok
    end)
  end

  def mark_bounced(%__MODULE__{} = delivery, reason \\ "bounce") do
    delivery
    |> changeset(%{status: "bounced", error: format_reason(reason)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        suppress_delivery_recipient(updated, "bounced")
        record_attempt(updated, "bounced", %{error: format_reason(reason)})

      _ ->
        :ok
    end)
  end

  def mark_complained(%__MODULE__{} = delivery, reason \\ "complaint") do
    delivery
    |> changeset(%{status: "complained", error: format_reason(reason)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        suppress_delivery_recipient(updated, "complained")
        record_attempt(updated, "complained", %{error: format_reason(reason)})

      _ ->
        :ok
    end)
  end

  def mark_suppressed(%__MODULE__{} = delivery, reason \\ "suppressed") do
    delivery
    |> changeset(%{status: "suppressed", error: format_reason(reason)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> record_attempt(updated, "suppressed", %{error: format_reason(reason)})
      _ -> :ok
    end)
  end

  def mark_paused(%__MODULE__{} = delivery, reason \\ "paused") do
    delivery
    |> changeset(%{status: "paused", error: format_reason(reason)})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> record_attempt(updated, "paused", %{error: format_reason(reason)})
      _ -> :ok
    end)
  end

  def requeue(%__MODULE__{} = delivery) do
    delivery
    |> changeset(%{status: "pending", error: nil, response_code: nil})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        with {:ok, _job} <- Elektrine.Email.ExternalDeliveryWorker.enqueue(updated) do
          {:ok, updated}
        end

      error ->
        error
    end
  end

  def mark_bounced_by_trace(trace_id, reason \\ "bounce") do
    case delivery_by_trace(trace_id) do
      %__MODULE__{} = delivery -> mark_bounced(delivery, reason)
      nil -> {:error, :not_found}
    end
  end

  def mark_complained_by_trace(trace_id, reason \\ "complaint") do
    case delivery_by_trace(trace_id) do
      %__MODULE__{} = delivery -> mark_complained(delivery, reason)
      nil -> {:error, :not_found}
    end
  end

  def mark_bounced_by_signal(attrs, reason \\ "bounce") when is_map(attrs) do
    case find_for_signal(attrs) do
      %__MODULE__{} = delivery -> mark_bounced(delivery, reason)
      nil -> {:error, :not_found}
    end
  end

  def apply_provider_event(attrs) when is_map(attrs) do
    event = fetch_attr(attrs, :event) || fetch_attr(attrs, :status) || ""
    reason = fetch_attr(attrs, :reason) || fetch_attr(attrs, :error) || event

    case find_for_signal(attrs) do
      %__MODULE__{} = delivery ->
        case normalize_event(event) do
          "sent" -> mark_sent(delivery, attrs)
          "accepted" -> mark_sent(delivery, attrs)
          "delivered" -> mark_sent(delivery, attrs)
          "deferred" -> mark_failed(delivery, "450 #{reason}")
          "bounced" -> mark_bounced(delivery, reason)
          "complained" -> mark_complained(delivery, reason)
          "complaint" -> mark_complained(delivery, reason)
          "suppressed" -> mark_suppressed(delivery, reason)
          _ -> {:error, :unknown_event}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def mark_complained_by_signal(attrs, reason \\ "complaint") when is_map(attrs) do
    case find_for_signal(attrs) do
      %__MODULE__{} = delivery -> mark_complained(delivery, reason)
      nil -> {:error, :not_found}
    end
  end

  defp delivery_by_trace(trace_id) when is_binary(trace_id) do
    Repo.one(from d in __MODULE__, where: d.trace_id == ^trace_id)
  end

  defp message_id_lookup_candidates(nil), do: []
  defp message_id_lookup_candidates(""), do: []

  defp message_id_lookup_candidates(message_id) do
    normalized =
      message_id
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^<|>$/, "")

    if normalized == "", do: [], else: Enum.uniq([normalized, "<#{normalized}>"])
  end

  defp duplicate_recipient?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:sent_message_id, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp normalize_event(event), do: event |> to_string() |> String.trim() |> String.downcase()

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp ratio(_count, 0), do: 0.0
  defp ratio(count, total), do: count / total

  defp validate_recipient_present(changeset) do
    recipients =
      ([get_field(changeset, :recipient)] ++
         (get_field(changeset, :to) || []) ++
         (get_field(changeset, :cc) || []) ++ (get_field(changeset, :bcc) || []))
      |> Enum.reject(&is_nil/1)

    if recipients == [] do
      add_error(changeset, :to, "must include at least one recipient")
    else
      changeset
    end
  end

  defp normalize_recipient_fields(changeset) do
    recipient = get_field(changeset, :recipient) |> normalize_email()
    trace_id = get_field(changeset, :trace_id) || Ecto.UUID.generate()

    changeset
    |> put_change(:recipient, recipient)
    |> put_change(:domain, email_domain(recipient))
    |> put_change(:trace_id, trace_id)
  end

  defp record_attempt(delivery, status, metadata) do
    attrs = %{
      delivery_id: delivery.id,
      attempt: delivery.attempts,
      status: status,
      provider: delivery.provider || provider_name(),
      provider_message_id: metadata[:provider_message_id] || delivery.provider_message_id,
      response_code: delivery.response_code,
      error: metadata[:error] || delivery.error,
      metadata: Map.new(metadata, fn {key, value} -> {to_string(key), value} end),
      attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Elektrine.Email.ExternalDeliveryAttempt{}
    |> Elektrine.Email.ExternalDeliveryAttempt.changeset(attrs)
    |> Repo.insert()
  end

  defp suppress_delivery_recipient(
         %__MODULE__{user_id: user_id, recipient: recipient} = delivery,
         reason
       )
       when is_integer(user_id) and is_binary(recipient) do
    Suppressions.suppress_recipient(user_id, recipient,
      reason: reason,
      source: "external_delivery",
      metadata: %{"delivery_id" => delivery.id, "trace_id" => delivery.trace_id}
    )
  end

  defp suppress_delivery_recipient(_, _), do: :ok

  defp provider_name do
    if Elektrine.EmailConfig.use_external_delivery_api?(), do: "haraka", else: "swoosh"
  end

  defp response_message_id(response) when is_map(response) do
    Map.get(response, :message_id) || Map.get(response, "message_id") ||
      Map.get(response, :provider_message_id) || Map.get(response, "provider_message_id")
  end

  # Fallback for non-map, non-nil responses: nothing to extract (avoids a
  # BadMapError from calling Map.get/2 on a value the type system proves is not
  # a map).
  defp response_message_id(_response), do: nil

  defp response_code(response) when is_map(response) do
    Map.get(response, :response_code) || Map.get(response, "response_code") ||
      Map.get(response, :status_code) || Map.get(response, "status_code")
  end

  defp response_code(reason) when is_binary(reason) do
    case Regex.run(~r/\b([245]\d\d)\b/, reason) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp response_code(_), do: nil

  defp classify_failure_status(reason) do
    code = response_code(reason)

    cond do
      is_binary(code) and String.starts_with?(code, "4") -> "deferred"
      is_binary(code) and String.starts_with?(code, "5") -> "bounced"
      true -> "failed"
    end
  end

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

  defp email_domain(nil), do: nil

  defp email_domain(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] -> String.downcase(domain)
      _ -> nil
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
