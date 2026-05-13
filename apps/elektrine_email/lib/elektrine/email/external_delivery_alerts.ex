defmodule Elektrine.Email.ExternalDeliveryAlerts do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias Elektrine.Accounts.User
  alias Elektrine.Email.ExternalDelivery
  alias Elektrine.Notifications
  alias Elektrine.Repo

  def check_and_notify(opts \\ []) do
    metrics = ExternalDelivery.operational_metrics(opts)
    alerts = alerts_for(metrics)

    if alerts != [] do
      notify_admins(alerts, metrics)
    end

    {:ok, %{alerts: alerts, metrics: metrics}}
  end

  def alerts_for(metrics) do
    thresholds = %{
      queue_depth: Application.get_env(:elektrine, :email_alert_queue_depth, 100),
      stuck_count: Application.get_env(:elektrine, :email_alert_stuck_count, 10),
      bounce_rate: Application.get_env(:elektrine, :email_alert_bounce_rate, 0.1),
      complaint_rate: Application.get_env(:elektrine, :email_alert_complaint_rate, 0.01)
    }

    []
    |> maybe_alert(metrics.queue_depth > thresholds.queue_depth, :queue_depth)
    |> maybe_alert(metrics.stuck_count > thresholds.stuck_count, :stuck_count)
    |> maybe_alert(metrics.bounce_rate > thresholds.bounce_rate, :bounce_rate)
    |> maybe_alert(metrics.complaint_rate > thresholds.complaint_rate, :complaint_rate)
  end

  defp maybe_alert(alerts, true, alert), do: [alert | alerts]
  defp maybe_alert(alerts, false, _alert), do: alerts

  defp notify_admins(alerts, metrics) do
    admins = Repo.all(from u in User, where: u.is_admin == true and u.banned == false)

    Enum.each(admins, fn admin ->
      Notifications.create_notification(%{
        user_id: admin.id,
        type: "email_delivery_alert",
        title: "Email delivery alert",
        body: "Alerts: #{Enum.map_join(alerts, ", ", &to_string/1)}",
        url: "/pripyat/email-delivery",
        source_type: "email_delivery",
        priority: "high",
        metadata: %{
          queue_depth: metrics.queue_depth,
          stuck_count: metrics.stuck_count,
          bounce_rate: metrics.bounce_rate,
          complaint_rate: metrics.complaint_rate
        }
      })
    end)

    Logger.warning("Email delivery alerts: #{inspect(alerts)} metrics=#{inspect(metrics)}")
    :ok
  end
end
