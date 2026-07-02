defmodule ElektrineWeb.API.PushSubscriptionController do
  @moduledoc """
  Browser Web Push subscription endpoints for API-compatible clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Push
  alias Elektrine.Push.WebSubscription

  action_fallback ElektrineWeb.FallbackController

  def show(conn, _params) do
    user = conn.assigns[:current_user]

    case Push.get_web_subscription(user.id) do
      %WebSubscription{} = subscription ->
        json(conn, format_subscription(subscription))

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "subscription not found"})
    end
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case Push.upsert_web_subscription(user.id, params) do
      {:ok, subscription} ->
        conn
        |> put_status(:created)
        |> json(format_subscription(subscription))

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)

      {:error, reason} ->
        bad_request(conn, reason)
    end
  end

  def update(conn, params) do
    user = conn.assigns[:current_user]

    case Push.update_web_subscription(user.id, params) do
      {:ok, subscription} ->
        json(conn, format_subscription(subscription))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "subscription not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def delete(conn, _params) do
    user = conn.assigns[:current_user]

    case Push.delete_web_subscription(user.id) do
      {:ok, _subscription} ->
        json(conn, %{})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "subscription not found"})
    end
  end

  defp format_subscription(%WebSubscription{} = subscription) do
    %{
      id: to_string(subscription.id),
      endpoint: subscription.endpoint,
      server_key: web_push_public_key(),
      alerts: subscription.alerts || %{},
      policy: subscription.policy || "all"
    }
  end

  defp web_push_public_key do
    :elektrine
    |> Application.get_env(:push, [])
    |> Keyword.get(:web_push_public_key)
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp bad_request(conn, reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: to_string(reason)})
  end
end
