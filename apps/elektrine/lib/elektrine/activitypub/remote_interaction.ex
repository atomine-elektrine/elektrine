defmodule Elektrine.ActivityPub.RemoteInteraction do
  @moduledoc """
  Schema for tracking interactions (likes, shares, replies) on remote posts.

  When we cache a remote post, we can also track who has interacted with it.
  This allows us to show "Alice, Bob, and 3 others liked this" on remote posts,
  similar to how Akkoma stores likes as an array of actor URIs.

  ## Design

  Instead of storing interaction actors directly in the message (which would
  require JSONB operations), we use a separate table. This is more normalized
  and allows for efficient queries like "has this user liked this post?".
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  @type interaction_type :: :like | :share | :reply | :emoji_react

  schema "remote_interactions" do
    field(:interaction_type, Ecto.Enum, values: [:like, :share, :reply, :emoji_react])
    field(:actor_uri, :string)
    # For emoji_react type
    field(:emoji, :string)

    belongs_to(:message, Elektrine.Messaging.Message)
    belongs_to(:remote_actor, Elektrine.ActivityPub.Actor)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [:interaction_type, :actor_uri, :emoji, :message_id, :remote_actor_id])
    |> validate_required([:interaction_type, :actor_uri, :message_id])
    |> unique_constraint([:message_id, :actor_uri, :interaction_type, :emoji],
      name: :remote_interactions_unique_index
    )
  end

  @doc """
  Records a remote interaction on a cached post.
  """
  def record_interaction(message_id, actor_uri, type, opts \\ []) do
    remote_actor_id = Keyword.get(opts, :remote_actor_id)
    emoji = Keyword.get(opts, :emoji)

    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      actor_uri: actor_uri,
      interaction_type: type,
      remote_actor_id: remote_actor_id,
      emoji: emoji
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Removes a remote interaction.
  """
  def remove_interaction(message_id, actor_uri, type, opts \\ []) do
    emoji = Keyword.get(opts, :emoji)

    query =
      from(i in __MODULE__,
        where: i.message_id == ^message_id,
        where: i.actor_uri == ^actor_uri,
        where: i.interaction_type == ^type
      )

    query =
      if emoji do
        where(query, [i], i.emoji == ^emoji)
      else
        query
      end

    Repo.delete_all(query)
  end

  @doc """
  Gets all actors who performed a specific interaction on a message.
  Returns a list of actor URIs.
  """
  def get_interaction_actors(message_id, type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(i in __MODULE__,
      where: i.message_id == ^message_id,
      where: i.interaction_type == ^type,
      order_by: [desc: i.inserted_at],
      limit: ^limit,
      select: i.actor_uri
    )
    |> Repo.all()
  end

  @doc """
  Gets actors with their cached profile data (if available).
  """
  def get_interaction_actors_with_profiles(message_id, type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(i in __MODULE__,
      where: i.message_id == ^message_id,
      where: i.interaction_type == ^type,
      left_join: a in Actor,
      on: a.id == i.remote_actor_id,
      order_by: [desc: i.inserted_at],
      limit: ^limit,
      select: %{
        actor_uri: i.actor_uri,
        username: a.username,
        domain: a.domain,
        display_name: a.display_name,
        avatar_url: a.avatar_url
      }
    )
    |> Repo.all()
  end

  @doc """
  Checks if a specific actor has performed an interaction.
  """
  def has_interaction?(message_id, actor_uri, type) do
    from(i in __MODULE__,
      where: i.message_id == ^message_id,
      where: i.actor_uri == ^actor_uri,
      where: i.interaction_type == ^type,
      select: true
    )
    |> Repo.exists?()
  end

  @doc """
  Gets the count of interactions of a specific type.
  """
  def count_interactions(message_id, type) do
    from(i in __MODULE__,
      where: i.message_id == ^message_id,
      where: i.interaction_type == ^type,
      select: count(i.id)
    )
    |> Repo.one()
  end

  @doc """
  Gets all emoji reactions on a message, grouped by emoji.
  """
  def get_emoji_reactions(message_id) do
    from(i in __MODULE__,
      where: i.message_id == ^message_id,
      where: i.interaction_type == :emoji_react,
      group_by: i.emoji,
      select: {i.emoji, count(i.id)}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Syncs interaction actors from a collection fetch.
  Used when refreshing a remote post's engagement data.
  """
  def sync_interactions_from_collection(message_id, type, actor_uris) do
    # Get existing actors for this interaction
    existing =
      from(i in __MODULE__,
        where: i.message_id == ^message_id,
        where: i.interaction_type == ^type,
        select: i.actor_uri
      )
      |> Repo.all()
      |> MapSet.new()

    new_uris = MapSet.new(actor_uris)

    # Add new interactions
    to_add = MapSet.difference(new_uris, existing)

    Enum.each(to_add, fn actor_uri ->
      record_interaction(message_id, actor_uri, type)
    end)

    # Optionally remove interactions that no longer exist
    # (commented out because unlikes might not be in the collection)
    # to_remove = MapSet.difference(existing, new_uris)
    # Enum.each(to_remove, fn actor_uri ->
    #   remove_interaction(message_id, actor_uri, type)
    # end)

    {:ok, MapSet.size(to_add)}
  end
end
