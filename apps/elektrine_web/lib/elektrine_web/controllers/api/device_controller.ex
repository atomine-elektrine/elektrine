defmodule ElektrineWeb.API.DeviceController do
  @moduledoc """
  API controller for device registration (push notifications).
  """
  use ElektrineWeb, :controller

  alias Elektrine.Push

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/devices
  Lists all registered devices for the current user.
  """
  def index(conn, _params) do
    user = conn.assigns[:current_user]
    devices = Push.list_user_devices(user.id)

    conn
    |> put_status(:ok)
    |> json(%{devices: Enum.map(devices, &format_device/1)})
  end

  @doc """
  POST /api/devices
  Registers a device for push notifications.

  Params:
    - token: Device push token (required)
    - platform: "ios" or "android" (required)
    - app_version: App version string
    - device_name: User-friendly device name
    - device_model: Device model identifier
    - os_version: Operating system version
    - bundle_id: App bundle identifier
  """
  def create(conn, %{"device" => device_params}) do
    user = conn.assigns[:current_user]

    case Push.register_device(user.id, device_params) do
      {:ok, device} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Device registered successfully",
          device: format_device(device)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to register device", errors: format_errors(changeset)})
    end
  end

  def create(conn, params) when is_map(params) do
    # Support flat params (not nested under "device")
    if Map.has_key?(params, "token") do
      create(conn, %{"device" => params})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameters: token, platform"})
    end
  end

  @doc """
  DELETE /api/devices/:token
  Unregisters a device.
  """
  def delete(conn, %{"token" => token}) do
    user = conn.assigns[:current_user]

    # Verify the device belongs to this user
    case Push.get_device_by_token(token) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Device not found"})

      device when device.user_id != user.id ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to delete this device"})

      _device ->
        case Push.unregister_device(token) do
          {:ok, _} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Device unregistered successfully"})

          {:error, _reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to unregister device"})
        end
    end
  end

  # Private helpers

  defp format_device(device) do
    %{
      id: device.id,
      platform: device.platform,
      device_name: device.device_name,
      device_model: device.device_model,
      app_version: device.app_version,
      os_version: device.os_version,
      enabled: device.enabled,
      last_used_at: device.last_used_at,
      inserted_at: device.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
