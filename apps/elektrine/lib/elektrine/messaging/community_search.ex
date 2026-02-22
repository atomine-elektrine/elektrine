defmodule Elektrine.Messaging.CommunitySearch do
  @moduledoc """
  Handles searching for both local and federated communities.
  """

  import Ecto.Query
  alias Elektrine.{ActivityPub, Repo}
  alias Elektrine.Messaging.Conversation
  require Logger

  @doc """
  Searches for communities across both local and federated sources.

  Returns a list of:
  - Local communities matching the search
  - Federated mirror communities
  - Remote Group actors from the fediverse (if search looks like a handle)

  ## Examples

      search_communities("technology")
      search_communities("linux@lemmy.ml")
  """
  def search_communities(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)

    # Normalize query
    query = String.trim(query) |> String.downcase()

    if query == "" do
      []
    else
      # Search local communities
      local_results = search_local_communities(query, limit)

      # If query looks like a fediverse handle, try webfinger
      federated_results =
        if String.contains?(query, "@") do
          search_remote_groups(query, limit - length(local_results))
        else
          []
        end

      # Combine results
      (local_results ++ federated_results)
      |> Enum.take(limit)
      |> add_membership_info(user_id)
    end
  end

  @doc """
  Searches only local communities (including mirrors).
  """
  def search_local_communities(query, limit \\ 20) do
    query_pattern = "%#{query}%"

    from(c in Conversation,
      where:
        c.type == "community" and
          c.is_public == true and
          (ilike(c.name, ^query_pattern) or
             ilike(c.description, ^query_pattern) or
             ilike(c.community_category, ^query_pattern)),
      order_by: [
        # Prioritize non-federated (local) communities
        desc: fragment("CASE WHEN ? = false THEN 1 ELSE 0 END", c.is_federated_mirror),
        desc: c.member_count,
        desc: c.last_message_at
      ],
      limit: ^limit,
      preload: [:creator, :remote_group_actor]
    )
    |> Repo.all()
    |> Enum.map(fn community ->
      %{
        type: :local,
        community: community,
        name: community.name,
        description: community.description,
        member_count: community.member_count,
        is_federated_mirror: community.is_federated_mirror,
        remote_actor: community.remote_group_actor
      }
    end)
  end

  @doc """
  Searches for remote Group actors via WebFinger.
  Handles queries like "linux@lemmy.ml" or "!technology@lemmy.world"
  """
  def search_remote_groups(handle, limit \\ 5) do
    # Clean up handle - remove leading ! if present
    clean_handle = String.trim_leading(handle, "!")

    case ActivityPub.Fetcher.webfinger_lookup(clean_handle) do
      {:ok, actor_uri} ->
        case ActivityPub.get_or_fetch_actor(actor_uri) do
          {:ok, actor} ->
            if actor.actor_type == "Group" do
              # Check if we already have a mirror
              existing_mirror =
                Elektrine.Messaging.FederatedCommunities.get_mirror_by_remote_actor(actor.id)

              [
                %{
                  type: :remote,
                  remote_actor: actor,
                  name: extract_group_name(actor),
                  description: actor.summary && HtmlSanitizeEx.strip_tags(actor.summary),
                  member_count: extract_follower_count(actor),
                  is_federated_mirror: !is_nil(existing_mirror),
                  mirror_community: existing_mirror
                }
              ]
            else
              # Not a Group, ignore
              []
            end

          _ ->
            []
        end

      _ ->
        []
    end
    |> Enum.take(limit)
  end

  @doc """
  Follows a remote Group actor by creating a local mirror and sending Follow activity.
  """
  def follow_remote_group(user_id, group_actor_id) do
    with group_actor <- Repo.get(ActivityPub.Actor, group_actor_id),
         true <- group_actor && group_actor.actor_type == "Group",
         {:ok, mirror} <-
           Elektrine.Messaging.FederatedCommunities.create_or_get_mirror_community(group_actor),
         {:ok, _member} <- Elektrine.Messaging.join_conversation(mirror.id, user_id) do
      {:ok, mirror}
    else
      false -> {:error, :not_a_group}
      nil -> {:error, :actor_not_found}
      error -> error
    end
  end

  # Private helpers

  defp add_membership_info(results, nil), do: results

  defp add_membership_info(results, user_id) do
    # Get user's community memberships
    member_community_ids =
      from(cm in Elektrine.Messaging.ConversationMember,
        where: cm.user_id == ^user_id and is_nil(cm.left_at),
        select: cm.conversation_id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.map(results, fn result ->
      is_member =
        case result.type do
          :local ->
            MapSet.member?(member_community_ids, result.community.id)

          :remote ->
            result.is_federated_mirror && result.mirror_community &&
              MapSet.member?(member_community_ids, result.mirror_community.id)
        end

      Map.put(result, :is_member, is_member)
    end)
  end

  defp extract_group_name(actor) do
    # Extract community name from Group actor
    # Prefer preferredUsername, fall back to username
    actor.username || "community"
  end

  defp extract_follower_count(actor) do
    # Try to get follower count from metadata
    get_in(actor.metadata, ["followers", "totalItems"]) || 0
  end
end
