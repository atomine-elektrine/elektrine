defmodule Elektrine.Email.ExternalDomainThrottle do
  @moduledoc """
  Lightweight outbound domain throttle for external delivery workers.

  Disabled by default unless `:email_domain_throttle_enabled` is set, so tests and
  local development keep inline delivery behavior while production can slow down
  hot recipient domains independently.
  """

  @table :external_email_domain_throttle

  def check(nil), do: :ok

  def check(domain) do
    if enabled?() do
      ensure_table()

      now = System.system_time(:second)
      interval = domain_policy(domain).interval_seconds
      key = normalize_domain(domain)

      case :ets.lookup(@table, key) do
        [{^key, last_sent_at}] when now - last_sent_at < interval ->
          {:snooze, interval - (now - last_sent_at)}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  def record(nil), do: :ok

  def record(domain) do
    if enabled?() do
      ensure_table()
      :ets.insert(@table, {normalize_domain(domain), System.system_time(:second)})
    end

    :ok
  end

  def retry_backoff_seconds(domain, attempt, status \\ "deferred") do
    base = domain_policy(domain).retry_base_seconds
    cap = domain_policy(domain).retry_cap_seconds

    multiplier =
      case status do
        "deferred" -> trunc(:math.pow(2, max(attempt, 1) - 1))
        _ -> 1
      end

    min(cap, base * multiplier)
  end

  defp enabled? do
    Application.get_env(:elektrine, :email_domain_throttle_enabled, false) == true
  end

  defp interval_seconds do
    Application.get_env(:elektrine, :email_domain_throttle_interval_seconds, 1)
  end

  defp domain_policy(domain) do
    configured = Application.get_env(:elektrine, :email_domain_policies, %{})

    configured
    |> Map.get(normalize_domain(domain), %{})
    |> Map.new()
    |> then(&Map.merge(default_policy(), &1))
  rescue
    _ -> default_policy()
  end

  defp default_policy do
    %{interval_seconds: interval_seconds(), retry_base_seconds: 60, retry_cap_seconds: 3600}
  end

  defp normalize_domain(domain), do: domain |> to_string() |> String.downcase()

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
