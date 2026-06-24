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
      run_command(acme_sh(), ["--cron", "--home", acme_home()], "renewal")
    end
  end

  defp bootstrap_if_needed do
    acme_sh = acme_sh()

    case validate_executable_path(acme_sh) do
      :ok ->
        if File.exists?(acme_sh) do
          :ok
        else
          run_command(default_issue_executable(), [], "bootstrap")
        end

      {:error, reason} ->
        Logger.error("Wildcard ACME bootstrap failed: #{reason}")
        {:error, :invalid_executable}
    end
  end

  defp run_command(executable, args, action) when is_binary(executable) and is_list(args) do
    timeout = timeout_ms()

    Logger.info("Running wildcard ACME #{action}")

    case validate_executable_path(executable) do
      :ok ->
        case run_system_command(executable, args, timeout) do
          {output, 0} ->
            log_output(:info, "Wildcard ACME #{action} completed", output)
            :ok

          {output, status} ->
            log_output(:error, "Wildcard ACME #{action} failed with status #{status}", output)
            {:error, :acme_failed}

          :timeout ->
            Logger.error("Wildcard ACME #{action} timed out")
            {:error, :acme_timeout}
        end

      {:error, reason} ->
        Logger.error("Wildcard ACME #{action} failed: #{reason}")
        {:error, :invalid_executable}
    end
  rescue
    error ->
      Logger.error("Wildcard ACME #{action} crashed: #{Exception.message(error)}")
      {:error, :acme_crashed}
  end

  defp run_command(_executable, _args, action) do
    Logger.error("Wildcard ACME #{action} failed: invalid executable")
    {:error, :invalid_executable}
  end

  defp acme_sh do
    System.get_env("ACME_SH_BIN") || Path.join(acme_home(), "acme.sh")
  end

  defp default_issue_executable do
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

  defp validate_executable_path(executable) do
    cond do
      String.contains?(executable, "\0") ->
        {:error, "executable path contains NUL"}

      Path.type(executable) != :absolute ->
        {:error, "executable path must be absolute"}

      true ->
        :ok
    end
  end

  defp run_system_command(executable, args, timeout) do
    task =
      Task.async(fn ->
        System.cmd(executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> :timeout
    end
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
