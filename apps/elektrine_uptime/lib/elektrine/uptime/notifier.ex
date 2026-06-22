defmodule Elektrine.Uptime.Notifier do
  @moduledoc """
  Dispatches uptime alerts on incident transitions.

  Driven from `Elektrine.Uptime.CheckWorker` with the `transition` returned by
  `Elektrine.Uptime.record_check/2`:

    * `:went_down`  — alert once (in-app and/or email per monitor preferences)
    * `:recovered`  — recovery alert
    * `:still_down` / `:none` — no-op, so we never spam per check

  All sends are wrapped so a notification/email failure never crashes the worker.
  """

  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Mailer
  alias Elektrine.Notifications
  alias Elektrine.Uptime.Check
  alias Elektrine.Uptime.Email
  alias Elektrine.Uptime.Monitor

  @doc """
  Notify the monitor's owner about a transition. Always returns `:ok`.
  """
  def notify(%Monitor{} = monitor, %Check{} = check, :went_down) do
    maybe_in_app(monitor, fn ->
      Notifications.create_notification(%{
        user_id: monitor.user_id,
        type: "uptime_down",
        title: "#{monitor.name} is down",
        body: check.error || "Check failed",
        url: "/uptime",
        source_type: "uptime_monitor",
        source_id: monitor.id,
        priority: "high"
      })
    end)

    maybe_email(monitor, fn user -> Email.down_email(user, monitor, check) end)

    :ok
  end

  def notify(%Monitor{} = monitor, _check, :recovered) do
    maybe_in_app(monitor, fn ->
      Notifications.create_notification(%{
        user_id: monitor.user_id,
        type: "uptime_recovered",
        title: "#{monitor.name} recovered",
        body: "#{monitor.name} is responding again",
        url: "/uptime",
        source_type: "uptime_monitor",
        source_id: monitor.id,
        priority: "normal"
      })
    end)

    maybe_email(monitor, fn user -> Email.recovery_email(user, monitor) end)

    :ok
  end

  # :still_down / :none — no alert, no spam.
  def notify(%Monitor{}, _check, _transition), do: :ok

  defp maybe_in_app(%Monitor{notify_in_app: true} = monitor, fun)
       when is_integer(monitor.user_id) do
    safely("in-app notification", monitor, fun)
  end

  defp maybe_in_app(_monitor, _fun), do: :ok

  defp maybe_email(%Monitor{notify_email: true} = monitor, build_email)
       when is_integer(monitor.user_id) do
    safely("email", monitor, fn ->
      case Accounts.get_user!(monitor.user_id) do
        %{recovery_email: address} = user when is_binary(address) and address != "" ->
          user
          |> build_email.()
          |> Mailer.deliver_later()

        _ ->
          :ok
      end
    end)
  end

  defp maybe_email(_monitor, _build_email), do: :ok

  defp safely(label, %Monitor{id: id}, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("uptime #{label} failed for monitor #{id}: #{Exception.message(error)}")

      :ok
  catch
    kind, reason ->
      Logger.error("uptime #{label} failed for monitor #{id}: #{inspect({kind, reason})}")
      :ok
  end
end
