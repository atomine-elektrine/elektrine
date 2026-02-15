defmodule Elektrine.Messaging.RateLimiter do
  @moduledoc """
  Rate limiting for messaging system to prevent spam and abuse.
  """

  use GenServer
  require Logger

  # Rate limits per user
  @message_limit_per_minute 60
  @reaction_limit_per_minute 100
  @search_limit_per_minute 30
  @timeline_post_limit_per_hour 20
  @discussion_post_limit_per_hour 10
  @cross_context_promotion_limit_per_hour 5
  @dm_creation_limit_per_hour 50

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    # Clean up old entries every minute
    :timer.send_interval(60_000, self(), :cleanup)
    {:ok, state}
  end

  @doc """
  Checks if a user can send a message.
  """
  def can_send_message?(user_id) do
    GenServer.call(__MODULE__, {:check_rate_limit, user_id, :message, @message_limit_per_minute})
  end

  @doc """
  Checks if a user can add a reaction.
  """
  def can_add_reaction?(user_id) do
    GenServer.call(
      __MODULE__,
      {:check_rate_limit, user_id, :reaction, @reaction_limit_per_minute}
    )
  end

  @doc """
  Checks if a user can search.
  """
  def can_search?(user_id) do
    GenServer.call(__MODULE__, {:check_rate_limit, user_id, :search, @search_limit_per_minute})
  end

  @doc """
  Records a message send for rate limiting.
  """
  def record_message(user_id) do
    GenServer.cast(__MODULE__, {:record_action, user_id, :message})
  end

  @doc """
  Records a reaction for rate limiting.
  """
  def record_reaction(user_id) do
    GenServer.cast(__MODULE__, {:record_action, user_id, :reaction})
  end

  @doc """
  Records a search for rate limiting.
  """
  def record_search(user_id) do
    GenServer.cast(__MODULE__, {:record_action, user_id, :search})
  end

  @doc """
  Checks if a user can create a timeline post.
  """
  def can_create_timeline_post?(user_id) do
    GenServer.call(
      __MODULE__,
      {:check_rate_limit_hourly, user_id, :timeline_post, @timeline_post_limit_per_hour}
    )
  end

  @doc """
  Checks if a user can create a discussion post.
  """
  def can_create_discussion_post?(user_id) do
    GenServer.call(
      __MODULE__,
      {:check_rate_limit_hourly, user_id, :discussion_post, @discussion_post_limit_per_hour}
    )
  end

  @doc """
  Checks if a user can perform cross-context promotions.
  """
  def can_promote_cross_context?(user_id) do
    GenServer.call(
      __MODULE__,
      {:check_rate_limit_hourly, user_id, :cross_promotion,
       @cross_context_promotion_limit_per_hour}
    )
  end

  @doc """
  Checks if a user can create new DM conversations.
  """
  def can_create_dm?(user_id) do
    GenServer.call(
      __MODULE__,
      {:check_rate_limit_hourly, user_id, :dm_creation, @dm_creation_limit_per_hour}
    )
  end

  @doc """
  Records a timeline post creation.
  """
  def record_timeline_post(user_id) do
    GenServer.cast(__MODULE__, {:record_action_hourly, user_id, :timeline_post})
  end

  @doc """
  Records a discussion post creation.
  """
  def record_discussion_post(user_id) do
    GenServer.cast(__MODULE__, {:record_action_hourly, user_id, :discussion_post})
  end

  @doc """
  Records a cross-context promotion.
  """
  def record_cross_promotion(user_id) do
    GenServer.cast(__MODULE__, {:record_action_hourly, user_id, :cross_promotion})
  end

  @doc """
  Records a DM creation.
  """
  def record_dm_creation(user_id) do
    GenServer.cast(__MODULE__, {:record_action_hourly, user_id, :dm_creation})
  end

  # GenServer callbacks

  def handle_call({:check_rate_limit, user_id, action_type, limit}, _from, state) do
    key = {user_id, action_type}
    current_minute = div(System.system_time(:second), 60)

    user_actions = Map.get(state, key, %{})
    current_count = Map.get(user_actions, current_minute, 0)

    can_proceed = current_count < limit
    {:reply, can_proceed, state}
  end

  def handle_call({:check_rate_limit_hourly, user_id, action_type, limit}, _from, state) do
    key = {user_id, action_type, :hourly}
    current_hour = div(System.system_time(:second), 3600)

    user_actions = Map.get(state, key, %{})
    current_count = Map.get(user_actions, current_hour, 0)

    can_proceed = current_count < limit
    {:reply, can_proceed, state}
  end

  def handle_cast({:record_action, user_id, action_type}, state) do
    key = {user_id, action_type}
    current_minute = div(System.system_time(:second), 60)

    user_actions = Map.get(state, key, %{})
    current_count = Map.get(user_actions, current_minute, 0)

    updated_actions = Map.put(user_actions, current_minute, current_count + 1)
    updated_state = Map.put(state, key, updated_actions)

    {:noreply, updated_state}
  end

  def handle_cast({:record_action_hourly, user_id, action_type}, state) do
    key = {user_id, action_type, :hourly}
    current_hour = div(System.system_time(:second), 3600)

    user_actions = Map.get(state, key, %{})
    current_count = Map.get(user_actions, current_hour, 0)

    updated_actions = Map.put(user_actions, current_hour, current_count + 1)
    updated_state = Map.put(state, key, updated_actions)

    {:noreply, updated_state}
  end

  def handle_info(:cleanup, state) do
    current_minute = div(System.system_time(:second), 60)
    current_hour = div(System.system_time(:second), 3600)
    # Keep 5 minutes of history
    cutoff_minute = current_minute - 5
    # Keep 2 hours of history
    cutoff_hour = current_hour - 2

    cleaned_state =
      Enum.reduce(state, %{}, fn {key, user_actions}, acc ->
        cutoff =
          case key do
            {_user_id, _action_type, :hourly} -> cutoff_hour
            _ -> cutoff_minute
          end

        cleaned_actions =
          Enum.filter(user_actions, fn {time_unit, _count} ->
            time_unit > cutoff
          end)
          |> Enum.into(%{})

        if map_size(cleaned_actions) > 0 do
          Map.put(acc, key, cleaned_actions)
        else
          acc
        end
      end)

    {:noreply, cleaned_state}
  end
end
