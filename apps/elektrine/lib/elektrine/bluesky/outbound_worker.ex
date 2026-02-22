defmodule Elektrine.Bluesky.OutboundWorker do
  @moduledoc """
  Durable outbound Bluesky sync worker.

  This replaces fire-and-forget async calls with persisted Oban jobs.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 8,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:action, :message_id, :user_id, :follower_id, :followed_id]
    ]

  require Logger

  alias Elektrine.Bluesky
  alias Elektrine.Messaging
  alias Oban.Job

  @action_mirror_post "mirror_post"
  @action_post_update "mirror_post_update"
  @action_post_delete "mirror_post_delete"
  @action_like "mirror_like"
  @action_unlike "mirror_unlike"
  @action_repost "mirror_repost"
  @action_unrepost "mirror_unrepost"
  @action_follow "mirror_follow"
  @action_unfollow "mirror_unfollow"

  @impl Oban.Worker
  def perform(%Job{args: %{"action" => action} = args}) do
    action
    |> dispatch(args)
    |> normalize_result(action, args)
  end

  def perform(%Job{}), do: :ok

  def enqueue_mirror_post(message_id),
    do: enqueue(@action_mirror_post, %{"message_id" => message_id})

  def enqueue_post_update(message_id),
    do: enqueue(@action_post_update, %{"message_id" => message_id})

  def enqueue_post_delete(message_id),
    do: enqueue(@action_post_delete, %{"message_id" => message_id})

  def enqueue_like(message_id, user_id),
    do: enqueue(@action_like, %{"message_id" => message_id, "user_id" => user_id})

  def enqueue_unlike(message_id, user_id),
    do: enqueue(@action_unlike, %{"message_id" => message_id, "user_id" => user_id})

  def enqueue_repost(message_id, user_id),
    do: enqueue(@action_repost, %{"message_id" => message_id, "user_id" => user_id})

  def enqueue_unrepost(message_id, user_id),
    do: enqueue(@action_unrepost, %{"message_id" => message_id, "user_id" => user_id})

  def enqueue_follow(follower_id, followed_id),
    do: enqueue(@action_follow, %{"follower_id" => follower_id, "followed_id" => followed_id})

  def enqueue_unfollow(follower_id, followed_id),
    do: enqueue(@action_unfollow, %{"follower_id" => follower_id, "followed_id" => followed_id})

  def enqueue(action, args \\ %{}) when is_binary(action) and is_map(args) do
    args
    |> Map.put("action", action)
    |> new()
    |> Oban.insert()
  end

  defp dispatch(@action_mirror_post, %{"message_id" => message_id}) do
    with {:ok, id} <- ensure_integer(message_id),
         %{} = message <- Messaging.get_message(id) do
      Bluesky.mirror_post(message)
    else
      nil -> {:skipped, :message_not_found}
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp dispatch(@action_post_update, %{"message_id" => message_id}) do
    with {:ok, id} <- ensure_integer(message_id),
         %{} = message <- Messaging.get_message(id) do
      Bluesky.mirror_post_update(message)
    else
      nil -> {:skipped, :message_not_found}
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp dispatch(@action_post_delete, %{"message_id" => message_id}) do
    with {:ok, id} <- ensure_integer(message_id),
         %{} = message <- Messaging.get_message(id) do
      Bluesky.mirror_post_delete(message)
    else
      nil -> {:skipped, :message_not_found}
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp dispatch(action, %{"message_id" => message_id, "user_id" => user_id})
       when action in [@action_like, @action_unlike, @action_repost, @action_unrepost] do
    with {:ok, parsed_message_id} <- ensure_integer(message_id),
         {:ok, parsed_user_id} <- ensure_integer(user_id) do
      case action do
        @action_like -> Bluesky.mirror_like(parsed_message_id, parsed_user_id)
        @action_unlike -> Bluesky.mirror_unlike(parsed_message_id, parsed_user_id)
        @action_repost -> Bluesky.mirror_repost(parsed_message_id, parsed_user_id)
        @action_unrepost -> Bluesky.mirror_unrepost(parsed_message_id, parsed_user_id)
      end
    else
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp dispatch(action, %{"follower_id" => follower_id, "followed_id" => followed_id})
       when action in [@action_follow, @action_unfollow] do
    with {:ok, parsed_follower_id} <- ensure_integer(follower_id),
         {:ok, parsed_followed_id} <- ensure_integer(followed_id) do
      case action do
        @action_follow -> Bluesky.mirror_follow(parsed_follower_id, parsed_followed_id)
        @action_unfollow -> Bluesky.mirror_unfollow(parsed_follower_id, parsed_followed_id)
      end
    else
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp dispatch(_action, _args), do: {:skipped, :unsupported_action}

  defp normalize_result(:ok, _action, _args), do: :ok
  defp normalize_result({:ok, _value}, _action, _args), do: :ok
  defp normalize_result({:skipped, _reason}, _action, _args), do: :ok

  defp normalize_result({:error, reason}, action, _args) do
    if retryable_reason?(reason) do
      Logger.warning("Bluesky outbound action #{action} failed (retrying): #{inspect(reason)}")
      {:error, reason}
    else
      Logger.warning("Bluesky outbound action #{action} skipped after error: #{inspect(reason)}")
      :ok
    end
  end

  defp normalize_result(other, action, args) do
    Logger.warning(
      "Bluesky outbound action #{action} returned unexpected result #{inspect(other)} for #{inspect(args)}"
    )

    :ok
  end

  defp retryable_reason?({:http_error, _reason}), do: true
  defp retryable_reason?({_, status}) when is_integer(status), do: status == 429 or status >= 500
  defp retryable_reason?(_reason), do: false

  defp ensure_integer(value) when is_integer(value), do: {:ok, value}

  defp ensure_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp ensure_integer(_value), do: {:error, :invalid_integer}
end
