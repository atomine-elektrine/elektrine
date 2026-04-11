defmodule Elektrine.Messaging.FederatedCommunities do
  @moduledoc """
  Community mirroring is disabled.

  Remote communities should stay remote actors and be browsed through remote
  routes instead of creating local fake communities.
  """

  require Logger

  def create_or_get_mirror_community(group_actor) do
    Logger.info("Skipping mirror-community creation for remote group #{group_actor.uri}")
    {:error, :mirroring_disabled}
  end

  def get_mirror_by_remote_actor(_remote_actor_id), do: nil

  def get_mirror_by_source(_source_uri), do: nil

  def link_message_to_mirror(_message_id, _group_actor_id), do: {:error, :mirroring_disabled}

  def ensure_mirror_exists(_group_actor_id), do: {:error, :mirroring_disabled}

  def backfill_mirror_messages(_mirror_community), do: {:error, :mirroring_disabled}
end
