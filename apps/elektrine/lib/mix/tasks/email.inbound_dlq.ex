defmodule Mix.Tasks.Email.InboundDlq do
  use Mix.Task

  import Ecto.Query

  alias Elektrine.Repo
  alias Oban.Job

  @shortdoc "Inspect and replay discarded Haraka inbound jobs"

  @moduledoc """
  Manage discarded jobs in the `email_inbound` queue.

  Examples:
    mix email.inbound_dlq
    mix email.inbound_dlq --limit 50
    mix email.inbound_dlq --requeue 12345
    mix email.inbound_dlq --requeue-all --limit 25
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [limit: :integer, requeue: :integer, requeue_all: :boolean]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    limit = max(1, Keyword.get(opts, :limit, 20))

    cond do
      is_integer(opts[:requeue]) ->
        replay_job(opts[:requeue])

      opts[:requeue_all] ->
        replay_all(limit)

      true ->
        list_discarded(limit)
    end
  end

  defp list_discarded(limit) do
    jobs = discarded_jobs(limit)

    if jobs == [] do
      Mix.shell().info("No discarded jobs in queue email_inbound.")
    else
      Mix.shell().info("Discarded jobs in queue email_inbound:")

      Enum.each(jobs, fn job ->
        Mix.shell().info(
          "  id=#{job.id} attempts=#{job.attempt}/#{job.max_attempts} inserted_at=#{job.inserted_at} reason=#{last_error(job)}"
        )
      end)
    end
  end

  defp replay_all(limit) do
    jobs = discarded_jobs(limit)

    if jobs == [] do
      Mix.shell().info("No discarded jobs to replay.")
    else
      Mix.shell().info("Replaying #{length(jobs)} discarded job(s)...")

      Enum.each(jobs, &replay_job(&1.id))
    end
  end

  defp replay_job(job_id) do
    case Repo.get(Job, job_id) do
      %Job{queue: "email_inbound", state: "discarded"} = job ->
        payload = job.args["payload"]
        remote_ip = job.args["remote_ip"]

        if is_map(payload) do
          case enqueue_replay(payload, remote_ip) do
            {:ok, replay_job, outcome} ->
              Mix.shell().info(
                "Replayed discarded job #{job.id} -> new_job=#{replay_job.id} outcome=#{outcome}"
              )

            {:error, reason} ->
              Mix.shell().error("Failed replay for job #{job.id}: #{inspect(reason)}")
          end
        else
          Mix.shell().error("Job #{job.id} has no valid payload; cannot replay.")
        end

      %Job{} ->
        Mix.shell().error("Job #{job_id} is not a discarded email_inbound job.")

      nil ->
        Mix.shell().error("Job #{job_id} not found.")
    end
  end

  defp enqueue_replay(payload, remote_ip) do
    worker_module = Module.concat([ElektrineWeb, HarakaInboundWorker])

    if Code.ensure_loaded?(worker_module) and function_exported?(worker_module, :enqueue, 2) do
      apply(worker_module, :enqueue, [payload, [remote_ip: remote_ip]])
    else
      args = %{
        "payload" => payload,
        "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "remote_ip" =>
          if(is_binary(remote_ip), do: remote_ip, else: to_string(remote_ip || "unknown")),
        "idempotency_key" => replay_idempotency_key(payload)
      }

      job =
        Oban.Job.new(args,
          worker: "Elixir.ElektrineWeb.HarakaInboundWorker",
          queue: "email_inbound",
          max_attempts: 10
        )

      case Oban.insert(job) do
        {:ok, inserted} -> {:ok, inserted, :queued}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp discarded_jobs(limit) do
    from(j in Job,
      where: j.queue == "email_inbound" and j.state == "discarded",
      order_by: [desc: j.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp last_error(%Job{errors: errors}) when is_list(errors) and errors != [] do
    case List.last(errors) do
      %{"error" => error} -> error
      %{error: error} -> error
      other -> inspect(other)
    end
  end

  defp last_error(_), do: "unknown"

  defp replay_idempotency_key(payload) when is_map(payload) do
    base =
      [
        payload["message_id"],
        payload["from"] || payload["mail_from"],
        payload["rcpt_to"] || payload["to"],
        payload["subject"]
      ]
      |> Enum.map(fn value ->
        case value do
          nil -> ""
          value when is_binary(value) -> String.trim(value)
          value -> to_string(value)
        end
      end)
      |> Enum.join("|")

    :crypto.hash(:sha256, base)
    |> Base.encode16(case: :lower)
  end

  defp replay_idempotency_key(_), do: Ecto.UUID.generate() |> String.replace("-", "")
end
