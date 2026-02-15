defmodule Elektrine.Messaging.FederatedCommunities do
  @moduledoc """
  Handles mirroring and integration of federated communities (Lemmy, Guppe groups, etc.)
  into the local community system for seamless native experience.
  """

  import Ecto.Query
  alias Elektrine.{Repo, ActivityPub}
  alias Elektrine.Messaging.{Conversation, Message}
  require Logger

  @doc """
  Creates or updates a local mirror community for a remote Group actor.
  This allows federated communities to appear in user's community list natively.

  Returns {:ok, conversation} or {:error, reason}
  """
  def create_or_get_mirror_community(group_actor) do
    # Check if mirror already exists
    case get_mirror_by_remote_actor(group_actor.id) do
      nil ->
        create_new_mirror(group_actor)

      existing ->
        {:ok, existing}
    end
  end

  @doc """
  Gets a mirror community by remote group actor ID.
  """
  def get_mirror_by_remote_actor(remote_actor_id) do
    from(c in Conversation,
      where: c.remote_group_actor_id == ^remote_actor_id and c.is_federated_mirror == true
    )
    |> Repo.one()
  end

  @doc """
  Gets a mirror community by federated source URI.
  """
  def get_mirror_by_source(source_uri) do
    from(c in Conversation,
      where: c.federated_source == ^source_uri and c.is_federated_mirror == true
    )
    |> Repo.one()
  end

  @doc """
  Links a federated message to its mirror community.
  Updates the message's conversation_id to point to the local mirror.
  """
  def link_message_to_mirror(message_id, group_actor_id) do
    with {:ok, mirror} <- ensure_mirror_exists(group_actor_id),
         message <- Repo.get(Message, message_id) do
      # Update message to link to mirror community
      message
      |> Message.metadata_changeset(
        %{
          # Note: We can't use regular changeset because federated messages
          # don't have sender_id. We'll need to update directly.
        }
      )

      # Direct update to avoid validation issues
      from(m in Message, where: m.id == ^message_id)
      |> Repo.update_all(
        set: [
          conversation_id: mirror.id,
          updated_at: DateTime.utc_now()
        ]
      )

      {:ok, mirror}
    else
      error -> error
    end
  end

  @doc """
  Ensures a mirror community exists for a Group actor.
  Creates it if it doesn't exist.
  """
  def ensure_mirror_exists(group_actor_id) when is_integer(group_actor_id) do
    case get_mirror_by_remote_actor(group_actor_id) do
      nil ->
        group_actor = Repo.get(ActivityPub.Actor, group_actor_id)

        if group_actor do
          create_new_mirror(group_actor)
        else
          {:error, :actor_not_found}
        end

      mirror ->
        {:ok, mirror}
    end
  end

  @doc """
  Links all existing federated messages from a Group actor to the mirror community.
  Call this after creating a new mirror to backfill existing posts.
  """
  def backfill_mirror_messages(mirror_community) do
    # Find all messages from this remote actor without a conversation_id
    message_ids =
      from(m in Message,
        where:
          m.remote_actor_id == ^mirror_community.remote_group_actor_id and
            m.federated == true and
            is_nil(m.conversation_id),
        select: m.id
      )
      |> Repo.all()

    if message_ids != [] do
      # Update all messages to link to mirror
      {count, _} =
        from(m in Message, where: m.id in ^message_ids)
        |> Repo.update_all(
          set: [
            conversation_id: mirror_community.id,
            updated_at: DateTime.utc_now()
          ]
        )

      Logger.info("Backfilled #{count} messages to mirror community #{mirror_community.name}")
      {:ok, count}
    else
      {:ok, 0}
    end
  end

  # Private functions

  defp create_new_mirror(group_actor) do
    # Extract community name from URI
    # e.g., https://lemmy.ml/c/technology -> technology_lemmy_ml
    name = generate_mirror_name(group_actor)

    # Extract category from metadata or default
    category = extract_category(group_actor) || "general"

    # Get description from summary
    description =
      if group_actor.summary do
        # Strip HTML and truncate
        group_actor.summary
        |> HtmlSanitizeEx.strip_tags()
        |> String.slice(0, 500)
      else
        "Federated community from #{group_actor.domain}"
      end

    attrs = %{
      name: name,
      description: description,
      type: "community",
      is_public: true,
      allow_public_posts: true,
      discussion_style: "forum",
      community_category: category,
      federated_source: group_actor.uri,
      is_federated_mirror: true,
      remote_group_actor_id: group_actor.id,
      avatar_url: group_actor.avatar_url,
      # Use system user as creator
      creator_id: get_system_user_id()
    }

    case %Conversation{}
         |> Conversation.changeset(attrs)
         |> Repo.insert() do
      {:ok, mirror} ->
        Logger.info("Created mirror community #{mirror.name} for #{group_actor.uri}")

        # Backfill existing messages
        Task.start(fn ->
          backfill_mirror_messages(mirror)
        end)

        {:ok, mirror}

      {:error, changeset} ->
        Logger.error("Failed to create mirror community: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp generate_mirror_name(group_actor) do
    # Extract community name from URI or use username
    # https://lemmy.ml/c/technology -> technology_lemmy_ml
    # Ensure uniqueness and valid format

    base_name =
      case extract_community_slug(group_actor.uri) do
        nil -> group_actor.username || "community"
        slug -> slug
      end

    # Add domain suffix for uniqueness
    domain_suffix =
      group_actor.domain
      |> String.replace(".", "_")
      |> String.downcase()

    candidate =
      "#{base_name}_#{domain_suffix}"
      |> String.replace(~r/[^a-z0-9_]/, "")
      |> String.slice(0, 30)

    # Ensure uniqueness
    ensure_unique_name(candidate, 0)
  end

  defp extract_community_slug(uri) when is_binary(uri) do
    # Extract slug from URIs like:
    # https://lemmy.ml/c/technology -> technology
    # https://a.gup.pe/u/linux -> linux
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/")
        |> Enum.reject(&(&1 == ""))
        |> List.last()
        |> String.downcase()

      _ ->
        nil
    end
  end

  defp extract_community_slug(_), do: nil

  defp ensure_unique_name(base_name, suffix) do
    candidate =
      if suffix == 0 do
        base_name
      else
        "#{base_name}#{suffix}"
      end

    case Repo.get_by(Conversation, name: candidate) do
      nil -> candidate
      _exists -> ensure_unique_name(base_name, suffix + 1)
    end
  end

  defp extract_category(group_actor) do
    # Try to infer category from metadata, summary, or name
    # This is a best-effort guess
    keywords =
      "#{group_actor.summary || ""} #{group_actor.username || ""}"
      |> String.downcase()

    cond do
      String.contains?(keywords, ["tech", "programming", "linux", "software"]) -> "tech"
      String.contains?(keywords, ["gaming", "games"]) -> "gaming"
      String.contains?(keywords, ["art", "creative"]) -> "art"
      String.contains?(keywords, ["science"]) -> "science"
      String.contains?(keywords, ["music"]) -> "music"
      String.contains?(keywords, ["news", "world"]) -> "news"
      String.contains?(keywords, ["meme"]) -> "memes"
      true -> "general"
    end
  end

  defp get_system_user_id do
    # Get or create a system user for federated mirrors
    # This could be a special "Federation Bot" user
    case Repo.get_by(Elektrine.Accounts.User, username: "federation") do
      nil ->
        # Fall back to the first admin user.
        from(u in Elektrine.Accounts.User,
          where: u.is_admin == true,
          limit: 1
        )
        |> Repo.one()
        |> case do
          # Fallback to user ID 1
          nil -> 1
          user -> user.id
        end

      user ->
        user.id
    end
  end
end
