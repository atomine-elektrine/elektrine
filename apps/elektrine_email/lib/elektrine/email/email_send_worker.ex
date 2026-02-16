defmodule Elektrine.Email.EmailSendWorker do
  @moduledoc """
  Compatibility shim for legacy outbound job APIs.

  This module used to run a custom GenServer queue backed by `email_jobs`.
  Outbound delivery now runs on Oban via `Elektrine.Email.SendEmailWorker`.
  """

  alias Elektrine.Email.SendEmailWorker
  alias Elektrine.Repo

  @doc false
  @deprecated "EmailSendWorker is no longer a standalone process; use SendEmailWorker."
  def start_link(_opts), do: :ignore

  @doc """
  Queue an outbound email job using Oban.
  """
  @deprecated "Use Elektrine.Email.SendEmailWorker.enqueue/4"
  def queue_email(user_id, email_attrs, attachments \\ nil, opts \\ []) do
    SendEmailWorker.enqueue(user_id, email_attrs, attachments, opts)
  end

  @doc """
  Get status for a queued job by Oban job id.
  """
  @deprecated "Use Oban job queries directly when possible"
  def get_job_status(job_id) do
    with {:ok, normalized_id} <- normalize_job_id(job_id) do
      case Repo.get(Oban.Job, normalized_id) do
        nil -> {:error, :not_found}
        job -> {:ok, job}
      end
    end
  end

  defp normalize_job_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_job_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_job_id}
    end
  end

  defp normalize_job_id(_), do: {:error, :invalid_job_id}
end
