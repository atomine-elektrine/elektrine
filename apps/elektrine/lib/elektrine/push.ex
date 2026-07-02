defmodule Elektrine.Push do
  @moduledoc """
  Push notification context for mobile apps.
  Handles device registration and notification delivery via APNs and FCM.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Elektrine.Profiles
  alias Elektrine.Push.DeviceToken
  alias Elektrine.Push.WebSubscription
  alias Elektrine.Repo

  @device_token_attr_keys %{
    "token" => :token,
    "token_hash" => :token_hash,
    "platform" => :platform,
    "app_version" => :app_version,
    "device_name" => :device_name,
    "device_model" => :device_model,
    "os_version" => :os_version,
    "bundle_id" => :bundle_id,
    "user_id" => :user_id,
    "enabled" => :enabled,
    "last_used_at" => :last_used_at,
    "failed_count" => :failed_count,
    "last_error" => :last_error
  }

  # Device token management

  @doc """
  Registers or updates a device for push notifications.
  If the token already exists, updates its metadata.
  """
  def register_device(user_id, attrs) do
    token = Map.get(attrs, :token) || Map.get(attrs, "token")
    token_hash = device_token_hash(token)

    # Upsert - update if token exists, create if new
    case Repo.get_by(DeviceToken, token_hash: token_hash) do
      nil ->
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.put(:user_id, user_id)
          |> Map.put(:token_hash, token_hash)
          |> Map.put(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))

        %DeviceToken{}
        |> DeviceToken.changeset(attrs)
        |> Repo.insert()

      existing ->
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.put(:user_id, user_id)
          |> Map.put(:token_hash, token_hash)
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
    case get_device_by_token(token) do
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
    Repo.get_by(DeviceToken, token_hash: device_token_hash(token))
  end

  @doc """
  Disables a device and records the error reason.
  """
  def disable_device(token, error_reason \\ nil) do
    case get_device_by_token(token) do
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
    case get_device_by_token(token) do
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
    case get_device_by_token(token) do
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

  def device_token_hash(token) when is_binary(token) do
    token
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def device_token_hash(_token), do: nil

  # Browser Web Push subscription management

  @default_web_alerts %{
    "follow" => true,
    "favourite" => true,
    "reblog" => true,
    "mention" => true,
    "poll" => true,
    "status" => false,
    "update" => false,
    "admin.sign_up" => false,
    "admin.report" => false
  }

  @doc """
  Creates or updates a browser Web Push subscription.
  """
  def upsert_web_subscription(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    attrs = normalize_web_subscription_attrs(user_id, attrs)

    case Repo.get_by(WebSubscription, endpoint_hash: attrs.endpoint_hash) do
      nil ->
        %WebSubscription{}
        |> WebSubscription.changeset(attrs)
        |> Repo.insert()

      %WebSubscription{} = subscription ->
        subscription
        |> WebSubscription.changeset(attrs)
        |> Repo.update()
    end
  end

  def upsert_web_subscription(_user_id, _attrs), do: {:error, :invalid_subscription}

  @doc """
  Gets the most recently used enabled browser Web Push subscription for a user.
  """
  def get_web_subscription(user_id) when is_integer(user_id) do
    WebSubscription
    |> where(user_id: ^user_id, enabled: true)
    |> order_by(desc: :last_used_at, desc: :updated_at, desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  def get_web_subscription(_user_id), do: nil

  @doc """
  Updates the current browser Web Push subscription policy for a user.
  """
  def update_web_subscription(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    case get_web_subscription(user_id) do
      nil ->
        {:error, :not_found}

      %WebSubscription{} = subscription ->
        subscription
        |> WebSubscription.update_changeset(normalize_web_subscription_policy(attrs))
        |> Repo.update()
    end
  end

  def update_web_subscription(_user_id, _attrs), do: {:error, :not_found}

  @doc """
  Deletes the current browser Web Push subscription for a user.
  """
  def delete_web_subscription(user_id) when is_integer(user_id) do
    case get_web_subscription(user_id) do
      nil -> {:error, :not_found}
      %WebSubscription{} = subscription -> Repo.delete(subscription)
    end
  end

  def delete_web_subscription(_user_id), do: {:error, :not_found}

  @doc """
  Lists enabled browser Web Push subscriptions for a user.
  """
  def list_web_subscriptions(user_id) when is_integer(user_id) do
    WebSubscription
    |> where(user_id: ^user_id, enabled: true)
    |> order_by(desc: :last_used_at, desc: :updated_at, desc: :id)
    |> Repo.all()
  end

  def list_web_subscriptions(_user_id), do: []

  @doc """
  Sends a notification payload to all eligible browser Web Push subscriptions.
  """
  def notify_web_user(user_id, notification) when is_integer(user_id) and is_map(notification) do
    subscriptions =
      user_id
      |> list_web_subscriptions()
      |> Enum.filter(&web_subscription_allows?(&1, notification))

    Enum.each(subscriptions, fn subscription ->
      Elektrine.Async.run(fn ->
        send_to_web_subscription(subscription, notification)
      end)
    end)

    {:ok, length(subscriptions)}
  end

  def notify_web_user(_user_id, _notification), do: {:ok, 0}

  @doc """
  Sends a notification payload to one browser Web Push subscription.
  """
  def send_to_web_subscription(%WebSubscription{} = subscription, notification)
      when is_map(notification) do
    payload = build_web_push_payload(notification)

    case deliver_web_push(subscription, payload) do
      {:ok, _result} ->
        record_web_push_success(subscription)
        :ok

      :ok ->
        record_web_push_success(subscription)
        :ok

      {:error, reason} ->
        record_web_push_failure(subscription, inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      reason = Exception.message(error)
      _ = record_web_push_failure(subscription, reason)
      {:error, reason}
  end

  def web_push_endpoint_hash(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def web_push_endpoint_hash(_endpoint), do: nil

  def record_web_push_success(%WebSubscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(%{
      failed_count: 0,
      last_error: nil,
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  def record_web_push_failure(%WebSubscription{} = subscription, error_reason) do
    new_count = subscription.failed_count + 1

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

    subscription
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
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
      Elektrine.Async.start(fn ->
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
    user_has_active_connection?(user_id, [])
  end

  @doc """
  Returns true if user should receive push notifications.
  (i.e., user is offline)
  """
  def should_send_push?(user_id) do
    not user_has_active_connection?(user_id)
  end

  @doc false
  def user_has_active_connection?(user_id, opts) when is_list(opts) do
    presence_module = Keyword.get(opts, :presence_module, ElektrineWeb.Presence)
    web_enabled? = Keyword.get_lazy(opts, :web_enabled?, fn -> component_enabled?(:web) end)

    presence_running? =
      Keyword.get_lazy(opts, :presence_running?, fn ->
        not is_nil(Process.whereis(presence_module))
      end)

    if web_enabled? and presence_running? do
      case safe_presence_get_by_key(presence_module, "mobile:users", to_string(user_id)) do
        [] -> false
        nil -> false
        _ -> true
      end
    else
      false
    end
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

  defp build_web_push_payload(notification) do
    %{
      title: notification[:title] || notification["title"],
      body: notification[:body] || notification["body"],
      badge: notification[:badge] || notification["badge"],
      icon: notification[:icon] || notification["icon"],
      data: notification[:data] || notification["data"] || %{}
    }
  end

  defp deliver_web_push(%WebSubscription{} = subscription, payload) do
    case web_push_client() do
      {module, opts} when is_atom(module) -> module.deliver(subscription, payload, opts)
      module when is_atom(module) -> module.deliver(subscription, payload, [])
    end
  end

  defp web_push_client do
    Application.get_env(:elektrine, :web_push_client, Elektrine.Push.WebPushClient)
  end

  defp push_enabled? do
    Application.get_env(:elektrine, :push, [])[:enabled] == true
  end

  defp apns_topic do
    Application.get_env(:elektrine, :push, [])[:apns_topic] || "com.elektrine.app"
  end

  defp safe_presence_get_by_key(presence_module, topic, key) do
    presence_module.get_by_key(topic, key)
  rescue
    error in ArgumentError ->
      Logger.warning(
        "Presence tracker unavailable while checking push eligibility: #{Exception.message(error)}"
      )

      []
  end

  defp component_enabled?(component) do
    :elektrine
    |> Application.get_env(:runtime_components, [])
    |> Keyword.get(component, true)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) ->
        case Map.fetch(@device_token_attr_keys, k) do
          {:ok, atom_key} -> [{atom_key, v}]
          :error -> []
        end

      {k, v} when is_atom(k) ->
        [{k, v}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp normalize_web_subscription_attrs(user_id, attrs) do
    subscription = Map.get(attrs, "subscription") || Map.get(attrs, :subscription) || attrs
    keys = Map.get(subscription, "keys") || Map.get(subscription, :keys) || %{}
    data = Map.get(attrs, "data") || Map.get(attrs, :data) || %{}
    endpoint = Map.get(subscription, "endpoint") || Map.get(subscription, :endpoint)

    %{
      user_id: user_id,
      endpoint: endpoint,
      endpoint_hash: web_push_endpoint_hash(endpoint),
      p256dh: Map.get(keys, "p256dh") || Map.get(keys, :p256dh),
      auth: Map.get(keys, "auth") || Map.get(keys, :auth),
      alerts: normalize_web_alerts(Map.get(data, "alerts") || Map.get(data, :alerts)),
      policy: normalize_web_policy(Map.get(data, "policy") || Map.get(data, :policy)),
      enabled: true,
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second),
      failed_count: 0,
      last_error: nil
    }
  end

  defp normalize_web_subscription_policy(attrs) do
    data = Map.get(attrs, "data") || Map.get(attrs, :data) || attrs

    %{
      alerts: normalize_web_alerts(Map.get(data, "alerts") || Map.get(data, :alerts)),
      policy: normalize_web_policy(Map.get(data, "policy") || Map.get(data, :policy)),
      enabled: true,
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp normalize_web_alerts(nil), do: @default_web_alerts

  defp normalize_web_alerts(alerts) when is_map(alerts) do
    alerts
    |> Map.new(fn {key, value} -> {to_string(key), value in [true, "true", "1", 1, "on"]} end)
    |> then(&Map.merge(@default_web_alerts, &1))
  end

  defp normalize_web_alerts(_alerts), do: @default_web_alerts

  defp normalize_web_policy(policy) when policy in ["all", "followed", "follower", "none"],
    do: policy

  defp normalize_web_policy(_policy), do: "all"

  defp web_subscription_allows?(%WebSubscription{} = subscription, notification) do
    alert_enabled?(subscription, notification) and policy_allows?(subscription, notification)
  end

  defp alert_enabled?(%WebSubscription{alerts: alerts}, notification) when is_map(alerts) do
    type = notification[:type] || notification["type"]

    type
    |> alert_keys_for_type()
    |> Enum.reduce_while(:missing, fn key, _status ->
      case Map.fetch(alerts, key) do
        {:ok, value} -> {:halt, value == true}
        :error -> {:cont, :missing}
      end
    end)
    |> case do
      :missing -> true
      allowed? -> allowed?
    end
  end

  defp alert_enabled?(_subscription, _notification), do: true

  defp alert_keys_for_type(type) do
    case to_string(type || "") do
      "like" -> ["like", "favourite", "favorite"]
      "reaction" -> ["reaction", "favourite", "favorite"]
      "boost" -> ["boost", "reblog"]
      "share" -> ["share", "reblog"]
      "new_message" -> ["new_message", "direct", "chat"]
      type -> [type]
    end
  end

  defp policy_allows?(%WebSubscription{policy: "none"}, _notification), do: false
  defp policy_allows?(%WebSubscription{policy: "all"}, _notification), do: true

  defp policy_allows?(%WebSubscription{policy: "followed", user_id: user_id}, notification) do
    case notification_actor_id(notification) do
      actor_id when is_integer(actor_id) -> Profiles.following?(user_id, actor_id)
      _ -> true
    end
  rescue
    _ -> false
  end

  defp policy_allows?(%WebSubscription{policy: "follower", user_id: user_id}, notification) do
    case notification_actor_id(notification) do
      actor_id when is_integer(actor_id) -> Profiles.following?(actor_id, user_id)
      _ -> true
    end
  rescue
    _ -> false
  end

  defp policy_allows?(_subscription, _notification), do: true

  defp notification_actor_id(notification) do
    case notification[:actor_id] || notification["actor_id"] do
      actor_id when is_integer(actor_id) ->
        actor_id

      actor_id when is_binary(actor_id) ->
        case Integer.parse(actor_id) do
          {id, ""} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
