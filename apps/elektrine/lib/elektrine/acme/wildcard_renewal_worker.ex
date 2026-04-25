defmodule Elektrine.ACME.WildcardRenewalWorker do
  @moduledoc """
  Runs wildcard certificate renewal through acme.sh on an Oban schedule.

  The worker intentionally delegates ACME protocol handling to acme.sh. Elektrine
  provides the DNS-01 hook and scheduling; acme.sh keeps renewal state and only
  renews certificates that are near expiry.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  @default_timeout_ms :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      run_renewal()
    else
      Logger.debug("Wildcard ACME renewal skipped: disabled")
      :ok
    end
  end

  def enqueue do
    %{}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  defp enabled? do
    System.get_env("ACME_WILDCARD_RENEWAL_ENABLED") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp run_renewal do
    with :ok <- bootstrap_if_needed() do
      run_command(System.get_env("ACME_RENEW_COMMAND") || default_renew_command(), "renewal")
    end
  end

  defp bootstrap_if_needed do
    acme_home = acme_home()
    acme_sh = System.get_env("ACME_SH_BIN") || Path.join(acme_home, "acme.sh")

    if File.exists?(acme_sh) do
      :ok
    else
      run_command(System.get_env("ACME_ISSUE_COMMAND") || default_issue_command(), "bootstrap")
    end
  end

  defp run_command(command, action) do
    timeout = timeout_ms()

    Logger.info("Running wildcard ACME #{action}")

    case System.cmd("/bin/sh", ["-lc", command], stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        log_output(:info, "Wildcard ACME #{action} completed", output)
        :ok

      {output, status} ->
        log_output(:error, "Wildcard ACME #{action} failed with status #{status}", output)
        {:error, :acme_failed}
    end
  rescue
    error ->
      Logger.error("Wildcard ACME #{action} crashed: #{Exception.message(error)}")
      {:error, :acme_crashed}
  end

  defp default_renew_command do
    acme_home = acme_home()
    acme_sh = System.get_env("ACME_SH_BIN") || Path.join(acme_home, "acme.sh")

    "#{shell_escape(acme_sh)} --cron --home #{shell_escape(acme_home)}"
  end

  defp default_issue_command do
    "/app/scripts/acme/issue_elektrine_wildcard_cert.sh"
  end

  defp acme_home do
    System.get_env("ACME_HOME") || "/data/acme.sh"
  end

  defp timeout_ms do
    case Integer.parse(System.get_env("ACME_RENEW_TIMEOUT_MS") || "") do
      {value, ""} when value > 0 -> value
      _ -> @default_timeout_ms
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp log_output(level, message, output) do
    output = String.trim(to_string(output))

    if output == "" do
      Logger.log(level, message)
    else
      Logger.log(level, "#{message}: #{output}")
    end
  end
end
