defmodule ElektrineWeb.Admin.EmailDeliveryController do
  @moduledoc false

  use ElektrineWeb, :controller

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, params) do
    status = blank_to_nil(params["status"])
    domain = blank_to_nil(params["domain"])

    metrics = email(:external_delivery_operational_metrics, [])

    deliveries =
      email(:recent_external_deliveries, [[status: status, domain: domain, limit: 100]])

    internal_deliveries = email(:recent_internal_deliveries, [[status: status, limit: 100]])

    controls = email(:active_external_delivery_controls, [])

    render(conn, :index,
      metrics: metrics,
      deliveries: deliveries,
      internal_deliveries: internal_deliveries,
      controls: controls,
      status: status || "",
      domain: domain || ""
    )
  end

  def requeue(conn, %{"id" => id}) do
    case email(:get_external_delivery, [id]) do
      nil ->
        put_flash(conn, :error, "Delivery not found.")

      delivery ->
        handle_result(conn, email(:requeue_external_delivery, [delivery]), "Delivery requeued.")
    end
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  def requeue_internal(conn, %{"id" => id}) do
    case email(:get_internal_delivery, [id]) do
      nil ->
        put_flash(conn, :error, "Internal delivery not found.")

      delivery ->
        handle_result(
          conn,
          email(:requeue_internal_delivery, [delivery]),
          "Internal delivery requeued."
        )
    end
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  def pause(conn, params) do
    result =
      email(:pause_external_delivery, [
        params["scope_type"] || "domain",
        params["scope_value"],
        [reason: params["reason"], paused_by_id: conn.assigns.current_user.id]
      ])

    conn
    |> handle_result(result, "Outbound delivery paused.")
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  def resume(conn, params) do
    conn
    |> handle_result(
      email(:resume_external_delivery, [params["scope_type"], params["scope_value"]]),
      "Outbound delivery resumed."
    )
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  def suppress(conn, params) do
    conn
    |> handle_result(
      email(:suppress_recipient, [
        parse_int(params["user_id"]),
        params["email"],
        [reason: params["reason"] || "manual", source: "admin"]
      ]),
      "Recipient suppressed."
    )
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  def unsuppress(conn, params) do
    case email(:unsuppress_recipient, [parse_int(params["user_id"]), params["email"]]) do
      {count, _} when count > 0 -> put_flash(conn, :info, "Recipient unsuppressed.")
      {:error, reason} -> put_flash(conn, :error, "Unsuppress failed: #{inspect(reason)}")
      _ -> put_flash(conn, :info, "No active suppression matched.")
    end
    |> redirect(to: ~p"/pripyat/email-delivery")
  end

  defp handle_result(conn, {:ok, _}, message), do: put_flash(conn, :info, message)

  defp handle_result(conn, {count, _}, message) when is_integer(count),
    do: put_flash(conn, :info, message)

  defp handle_result(conn, {:error, reason}, _message),
    do: put_flash(conn, :error, inspect(reason))

  defp email(function, args), do: apply(Elektrine.Email, function, args)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
