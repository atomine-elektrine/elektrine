defmodule Elektrine.Social.HomeFeedInvalidationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 120,
      keys: [:type, :user_id, :message_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Elektrine.Repo
  alias Elektrine.Social.{HomeFeed, Message}

  def clear_user(user_id, reason \\ :policy_changed) when is_integer(user_id) do
    enqueue_args(%{"type" => "clear_user", "user_id" => user_id, "reason" => to_string(reason)})
  end

  def remove_message(message_id) when is_integer(message_id) do
    enqueue_args(%{"type" => "remove_message", "message_id" => message_id})
  end

  def message_changed(message_id) when is_integer(message_id) do
    enqueue_args(%{"type" => "message_changed", "message_id" => message_id})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "clear_user", "user_id" => user_id} = args})
      when is_integer(user_id) do
    HomeFeed.clear(user_id, Map.get(args, "reason", "policy_changed"))
  end

  def perform(%Oban.Job{args: %{"type" => "remove_message", "message_id" => message_id}})
      when is_integer(message_id) do
    case load_message(message_id) do
      %Message{} = message -> HomeFeed.message_deleted(message)
      nil -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"type" => "message_changed", "message_id" => message_id}})
      when is_integer(message_id) do
    case load_message(message_id) do
      %Message{} = message -> HomeFeed.message_changed(message)
      nil -> :ok
    end
  end

  defp load_message(message_id) do
    Message
    |> Repo.get(message_id)
    |> case do
      %Message{} = message -> Repo.preload(message, [:remote_actor])
      nil -> nil
    end
  end

  defp enqueue_args(args) do
    if inline_testing?() do
      _ = perform(%Oban.Job{args: args})
      {:ok, %Oban.Job{args: args}}
    else
      args
      |> new()
      |> Oban.insert()
    end
  end

  defp inline_testing? do
    :elektrine
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing) == :inline
  end
end
