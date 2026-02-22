defmodule ElektrineWeb.HarakaInboundWorker do
  @moduledoc """
  Durable inbound Haraka processing worker.

  Webhook requests enqueue payloads here so processing can retry independently
  of the SMTP transaction path.
  """

  use Oban.Worker,
    queue: :email_inbound,
    max_attempts: 10,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      keys: [:idempotency_key],
      states: [:available, :scheduled, :executing, :retryable, :completed]
    ]

  alias Elektrine.Telemetry.Events
  alias ElektrineWeb.HarakaWebhookController

  @discard_reasons [
    :no_mailbox,
    :invalid_email,
    :security_rejection,
    :haraka_email_routing_validation_failed
  ]

  @doc """
  Enqueue a Haraka inbound payload for asynchronous processing.
  """
  def enqueue(payload, opts \\ []) when is_map(payload) do
    idempotency_key = idempotency_key(payload)

    case find_existing_job(idempotency_key) do
      %Oban.Job{} = job ->
        {:ok, job, :duplicate}

      nil ->
        args = %{
          "payload" => payload,
          "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "remote_ip" => normalize_remote_ip(Keyword.get(opts, :remote_ip)),
          "idempotency_key" => idempotency_key
        }

        case args |> new() |> Oban.insert() do
          {:ok, job} ->
            outcome = if Map.get(job, :conflict?, false), do: :duplicate, else: :queued
            {:ok, job, outcome}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    start_time = System.monotonic_time(:millisecond)
    payload = job.args["payload"] || %{}

    ingest_context = %{
      "ingest_mode" => "async",
      "job_id" => job.id,
      "received_at" => job.args["received_at"],
      "idempotency_key" => job.args["idempotency_key"],
      "remote_ip" => job.args["remote_ip"]
    }

    queue_lag_ms = queue_lag_ms(job.args["received_at"])

    case HarakaWebhookController.process_haraka_email_public(payload, ingest_context) do
      {:ok, _email} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:worker, :success, duration, %{
          source: :haraka,
          queue: :email_inbound,
          lag_ms: queue_lag_ms,
          job_id: job.id
        })

        :ok

      {:error, reason} when reason in @discard_reasons ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:worker, :discarded, duration, %{
          source: :haraka,
          queue: :email_inbound,
          lag_ms: queue_lag_ms,
          reason: reason,
          job_id: job.id
        })

        {:discard, reason}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.email_inbound(:worker, :failure, duration, %{
          source: :haraka,
          queue: :email_inbound,
          lag_ms: queue_lag_ms,
          reason: reason,
          job_id: job.id
        })

        {:error, reason}
    end
  end

  @doc """
  Builds a deterministic idempotency key for inbound Haraka payloads.
  """
  def idempotency_key(payload) when is_map(payload) do
    message_id = normalize_payload_value(payload["message_id"])
    from = normalize_payload_value(payload["from"] || payload["mail_from"])
    rcpt_to = normalize_payload_value(payload["rcpt_to"] || payload["to"])

    subject =
      payload["subject"]
      |> normalize_subject()
      |> normalize_payload_value()

    body_fingerprint =
      payload["text_body"]
      |> normalize_payload_value()
      |> then(&String.slice(&1, 0, 1_024))

    material =
      [message_id, from, rcpt_to, subject, body_fingerprint]
      |> Enum.map_join("|", &String.downcase/1)

    :crypto.hash(:sha256, material)
    |> Base.encode16(case: :lower)
  end

  defp normalize_payload_value(nil), do: ""
  defp normalize_payload_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_payload_value(value), do: value |> to_string() |> String.trim()

  defp normalize_subject([subject | _]) when is_binary(subject), do: subject
  defp normalize_subject(subject) when is_binary(subject), do: subject
  defp normalize_subject(_), do: ""

  defp normalize_remote_ip(nil), do: "unknown"
  defp normalize_remote_ip(value) when is_binary(value), do: value
  defp normalize_remote_ip(value), do: to_string(value)

  defp queue_lag_ms(nil), do: nil

  defp queue_lag_ms(received_at_iso8601) when is_binary(received_at_iso8601) do
    case DateTime.from_iso8601(received_at_iso8601) do
      {:ok, received_at, _offset} ->
        DateTime.diff(DateTime.utc_now(), received_at, :millisecond)

      _ ->
        nil
    end
  end

  defp find_existing_job(idempotency_key) do
    import Ecto.Query, only: [from: 2]

    query =
      from(j in Oban.Job,
        where:
          fragment("?->>'idempotency_key' = ?", j.args, ^idempotency_key) and
            j.worker == ^to_string(__MODULE__) and
            j.queue == "email_inbound" and
            j.state in ["available", "scheduled", "executing", "retryable", "completed"],
        order_by: [desc: j.id],
        limit: 1
      )

    Elektrine.Repo.one(query)
  end
end
