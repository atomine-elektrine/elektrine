defmodule Elektrine.ActivityPub.Handlers.BlockHandler do
  @moduledoc """
  Handles Block ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub

  @doc """
  Handles an incoming Block activity.
  Someone is blocking one of our users - we just acknowledge it.
  The remote instance handles the actual blocking.
  """
  def handle(%{"object" => blocked_uri}, actor_uri, _target_user) do
    with {:ok, _remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, _blocked_user} <- get_local_user_from_uri(blocked_uri) do
      # We don't need to do anything specific - the remote instance handles the blocking
      # In the future, we could record this to hide our user's posts from the blocker
      {:ok, :blocked}
    else
      {:error, :not_local} ->
        {:ok, :not_our_user}

      {:error, reason} ->
        Logger.warning("Failed to handle block: #{inspect(reason)}")
        {:error, :handle_block_failed}
    end
  end

  @doc """
  Handles Undo Block activity.
  Someone is unblocking one of our users.
  """
  def handle_undo(%{"object" => blocked_uri}, actor_uri) do
    with {:ok, _remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, _blocked_user} <- get_local_user_from_uri(blocked_uri) do
      # We don't need to do anything specific - the remote instance handles the unblocking
      {:ok, :unblocked}
    else
      {:error, :not_local} ->
        {:ok, :not_our_user}

      {:error, reason} ->
        Logger.warning("Failed to undo block: #{inspect(reason)}")
        {:error, :undo_block_failed}
    end
  end

  defp get_local_user_from_uri(uri) do
    base_url = ActivityPub.instance_url()

    cond do
      String.starts_with?(uri, "#{base_url}/users/") ->
        username = String.replace_prefix(uri, "#{base_url}/users/", "")

        case Elektrine.Accounts.get_user_by_username(username) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      String.starts_with?(uri, "#{base_url}/@") ->
        username = String.replace_prefix(uri, "#{base_url}/@", "")

        case Elektrine.Accounts.get_user_by_username(username) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      true ->
        {:error, :not_local}
    end
  end
end
