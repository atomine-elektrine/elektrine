defmodule Elektrine.Push do
  @moduledoc """
  Push notification context for mobile apps.
  Handles device registration and notification delivery via APNs and FCM.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Elektrine.Push.DeviceToken
  alias Elektrine.Repo

  # Device token management

  @doc """
  Registers or updates a device for push notifications.
  If the token already exists, updates its metadata.
  """
  def register_device(user_id, attrs) do
    token = Map.get(attrs, :token) || Map.get(attrs, "token")

    # Upsert - update if token exists, create if new
    case Repo.get_by(DeviceToken, token: token) do
      nil ->
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.put(:user_id, user_id)
          |> Map.put(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))

        %DeviceToken{}
        |> DeviceToken.changeset(attrs)
        |> Repo.insert()

      existing ->
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.put(:user_id, user_id)
          |> Map.put(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))
          |> Map.put(:enabled, true)
          |> Map.put(:failed_count, 0)
          |> Map.put(:last_error, nil)

        existing
        |> DeviceToken.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Unregisters a device by token.
  """
  def unregister_device(token) do
    case Repo.get_by(DeviceToken, token: token) do
      nil -> {:error, :not_found}
      device -> Repo.delete(device)
    end
  end

  @doc """
  Lists all enabled devices for a user.
  """
  def list_user_devices(user_id) do
    DeviceToken
    |> where(user_id: ^user_id, enabled: true)
    |> order_by(desc: :last_used_at)
    |> Repo.all()
  end

  @doc """
  Gets a device by its token.
  """
  def get_device_by_token(token) do
    Repo.get_by(DeviceToken, token: token)
  end

  @doc """
  Disables a device and records the error reason.
  """
  def disable_device(token, error_reason \\ nil) do
    case Repo.get_by(DeviceToken, token: token) do
      nil ->
        {:error, :not_found}

      device ->
        device
        |> Ecto.Changeset.change(%{
          enabled: false,
          failed_count: device.failed_count + 1,
          last_error: error_reason
        })
        |> Repo.update()
    end
  end

  @doc """
  Records a failed push attempt.
  Disables device after 5 consecutive failures.
  """
  def record_push_failure(token, error_reason) do
    case Repo.get_by(DeviceToken, token: token) do
      nil ->
        {:error, :not_found}

      device ->
        new_count = device.failed_count + 1

        changes =
          if new_count >= 5 do
            %{
              failed_count: new_count,
              last_error: error_reason,
              enabled: false
            }
          else
            %{
              failed_count: new_count,
              last_error: error_reason
            }
          end

        device
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
    end
  end

  @doc """
  Resets failure count on successful push.
  """
  def record_push_success(token) do
    case Repo.get_by(DeviceToken, token: token) do
      nil ->
        {:error, :not_found}

      device ->
        device
        |> Ecto.Changeset.change(%{
          failed_count: 0,
          last_error: nil,
          last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  # Push notification sending

  @doc """
  Sends a push notification to all of a user's devices.
  Returns the number of devices notified.
  """
  def notify_user(user_id, notification) do
    devices = list_user_devices(user_id)

    # Send to each device asynchronously
    Enum.each(devices, fn device ->
      Task.start(fn ->
        send_to_device(device, notification)
      end)
    end)

    {:ok, length(devices)}
  end

  @doc """
  Sends a push notification to a specific device.
  """
  def send_to_device(%DeviceToken{platform: "ios"} = device, notification) do
    if push_enabled?() do
      send_apns(device.token, notification)
    else
      Logger.debug("Push notifications disabled, skipping APNs send")
      :ok
    end
  end

  def send_to_device(%DeviceToken{platform: "android"} = device, notification) do
    if push_enabled?() do
      send_fcm(device.token, notification)
    else
      Logger.debug("Push notifications disabled, skipping FCM send")
      :ok
    end
  end

  def send_to_device(_device, _notification) do
    {:error, :unknown_platform}
  end

  # User online detection

  @doc """
  Checks if a user has an active WebSocket connection.
  Used to decide whether to send push or rely on WebSocket.
  """
  def user_has_active_connection?(user_id) do
    case ElektrineWeb.Presence.get_by_key("mobile:users", to_string(user_id)) do
      [] -> false
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns true if user should receive push notifications.
  (i.e., user is offline)
  """
  def should_send_push?(user_id) do
    not user_has_active_connection?(user_id)
  end

  # APNs and FCM implementation

  defp send_apns(device_token, notification) do
    # Pigeon is optional in some environments, so use apply/3 to avoid compile warnings.
    if Code.ensure_loaded?(Pigeon.APNS) do
      payload = build_apns_payload(notification)
      args = [payload, device_token, apns_topic()]

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apns_notification = apply(Pigeon.APNS.Notification, :new, args)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Pigeon, :push, [apns_notification]) do
        %{response: :success} = _result ->
          Logger.info("APNs push sent successfully")
          record_push_success(device_token)
          :ok

        %{response: :bad_device_token} = _result ->
          Logger.warning("APNs bad device token")
          disable_device(device_token, "bad_device_token")
          {:error, :bad_device_token}

        %{response: reason} = _result ->
          Logger.error("APNs push failed: #{inspect(reason)}")
          record_push_failure(device_token, to_string(reason))
          {:error, reason}
      end
    else
      Logger.warning("Pigeon not available for APNs push")
      {:error, :pigeon_not_available}
    end
  end

  defp send_fcm(device_token, notification) do
    # Pigeon is optional in some environments, so use apply/3 to avoid compile warnings.
    if Code.ensure_loaded?(Pigeon.FCM) do
      payload = build_fcm_payload(notification)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      fcm_notification = apply(Pigeon.FCM.Notification, :new, [device_token, payload])

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Pigeon, :push, [fcm_notification]) do
        %{response: :success} = _result ->
          Logger.info("FCM push sent successfully")
          record_push_success(device_token)
          :ok

        %{response: :not_registered} = _result ->
          Logger.warning("FCM device not registered")
          disable_device(device_token, "not_registered")
          {:error, :not_registered}

        %{response: reason} = _result ->
          Logger.error("FCM push failed: #{inspect(reason)}")
          record_push_failure(device_token, to_string(reason))
          {:error, reason}
      end
    else
      Logger.warning("Pigeon not available for FCM push")
      {:error, :pigeon_not_available}
    end
  end

  defp build_apns_payload(notification) do
    %{
      "aps" => %{
        "alert" => %{
          "title" => notification[:title] || notification["title"],
          "body" => notification[:body] || notification["body"]
        },
        "badge" => notification[:badge] || 1,
        "sound" => notification[:sound] || "default",
        "category" => notification[:category]
      },
      "data" => notification[:data] || %{}
    }
  end

  defp build_fcm_payload(notification) do
    %{
      "notification" => %{
        "title" => notification[:title] || notification["title"],
        "body" => notification[:body] || notification["body"]
      },
      "data" => notification[:data] || %{},
      "android" => %{
        "priority" => "high"
      }
    }
  end

  defp push_enabled? do
    Application.get_env(:elektrine, :push, [])[:enabled] == true
  end

  defp apns_topic do
    Application.get_env(:elektrine, :push, [])[:apns_topic] || "com.elektrine.app"
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
    |> Map.new()
  rescue
    ArgumentError -> attrs
  end
end
