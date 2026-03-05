defmodule Elektrine.ActivityPub.Handlers.MoveHandler do
  @moduledoc """
  Handles ActivityPub Move activities for account migration.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  @doc """
  Handles an incoming Move activity.
  """
  def handle(
        %{"actor" => actor_uri, "object" => object, "target" => target},
        _actor_uri,
        _target_user
      ) do
    with {:ok, old_actor_uri} <- extract_uri(object),
         {:ok, new_actor_uri} <- extract_uri(target),
         :ok <- validate_actor_match(actor_uri, old_actor_uri),
         {:ok, old_actor} <- ActivityPub.get_or_fetch_actor(old_actor_uri),
         {:ok, new_actor} <- ActivityPub.get_or_fetch_actor(new_actor_uri) do
      migrate_local_remote_follows(old_actor.id, new_actor.id)
      mark_actor_moved(old_actor, new_actor_uri)
      {:ok, :moved}
    else
      {:error, reason} ->
        Logger.warning("Ignoring Move activity: #{inspect(reason)}")
        {:ok, :ignored}
    end
  end

  def handle(_activity, _actor_uri, _target_user), do: {:ok, :unhandled}

  defp extract_uri(uri) when is_binary(uri) do
    trimmed = String.trim(uri)

    if trimmed == "" do
      {:error, :invalid_uri}
    else
      {:ok, trimmed}
    end
  end

  defp extract_uri(%{"id" => uri}) when is_binary(uri), do: extract_uri(uri)
  defp extract_uri(%{id: uri}) when is_binary(uri), do: extract_uri(uri)
  defp extract_uri(_), do: {:error, :invalid_uri}

  defp validate_actor_match(actor_uri, object_uri)
       when is_binary(actor_uri) and is_binary(object_uri) do
    if normalize_uri(actor_uri) == normalize_uri(object_uri) do
      :ok
    else
      {:error, :actor_object_mismatch}
    end
  end

  defp validate_actor_match(_, _), do: {:error, :actor_object_mismatch}

  defp normalize_uri(uri) when is_binary(uri),
    do: uri |> String.trim() |> String.trim_trailing("/")

  defp migrate_local_remote_follows(old_actor_id, new_actor_id)
       when is_integer(old_actor_id) and is_integer(new_actor_id) do
    follows =
      Follow
      |> where(
        [f],
        f.remote_actor_id == ^old_actor_id and not is_nil(f.follower_id) and is_nil(f.followed_id)
      )
      |> Repo.all()

    Enum.each(follows, fn follow ->
      if Profiles.get_follow_to_remote_actor(follow.follower_id, new_actor_id) do
        Repo.delete(follow)
      else
        follow
        |> Ecto.Changeset.change(remote_actor_id: new_actor_id)
        |> Repo.update()
      end
    end)
  end

  defp migrate_local_remote_follows(_, _), do: :ok

  defp mark_actor_moved(%Actor{} = old_actor, new_actor_uri) do
    metadata =
      (old_actor.metadata || %{})
      |> Map.put("movedTo", new_actor_uri)

    old_actor
    |> Actor.changeset(%{
      metadata: metadata,
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end
end
