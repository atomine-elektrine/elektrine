defmodule Elektrine.Messaging.Servers do
  @moduledoc """
  Context for Discord-style servers and server-scoped channels.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    Conversation,
    Conversations,
    Federation,
    Server,
    ServerMember
  }

  @doc """
  Lists all servers where the user has an active membership.
  """
  def list_servers(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(s in Server,
      join: sm in ServerMember,
      on: sm.server_id == s.id and sm.user_id == ^user_id and is_nil(sm.left_at),
      order_by: [desc: sm.inserted_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  @doc """
  Gets a server with channels for a user.
  """
  def get_server(server_id, user_id) do
    channel_query =
      from(c in Conversation,
        where: c.type == "channel",
        order_by: [asc: c.channel_position, asc: c.inserted_at]
      )

    from(s in Server,
      join: sm in ServerMember,
      on: sm.server_id == s.id and sm.user_id == ^user_id and is_nil(sm.left_at),
      where: s.id == ^server_id,
      preload: [:creator, channels: ^channel_query]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      server -> {:ok, server}
    end
  end

  @doc """
  Gets the active membership record for a user in a server.
  """
  def get_server_member(server_id, user_id) do
    from(sm in ServerMember,
      where: sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at)
    )
    |> Repo.one()
  end

  @doc """
  Creates a server and seeds it with a default `#general` channel.
  """
  def create_server(creator_id, attrs) do
    attrs = Map.put(attrs, :creator_id, creator_id)

    Repo.transaction(fn ->
      with {:ok, server} <- %Server{} |> Server.changeset(attrs) |> Repo.insert(),
           {:ok, _owner_member} <- do_add_member(server.id, creator_id, "owner"),
           {:ok, _general_channel} <- do_create_channel(server.id, creator_id, %{}) do
        get_server(server.id, creator_id)
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, server}} ->
        Federation.maybe_push_for_server(server.id)
        {:ok, server}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a text channel inside a server.
  Only owners/admins/moderators can create channels.
  """
  def create_server_channel(server_id, creator_id, attrs) do
    with %Server{} <- Repo.get(Server, server_id),
         %ServerMember{} = member <- get_server_member(server_id, creator_id),
         true <- member.role in ["owner", "admin", "moderator"] do
      Repo.transaction(fn ->
        do_create_channel(server_id, creator_id, attrs)
      end)
      |> case do
        {:ok, {:ok, channel}} ->
          Federation.maybe_push_for_server(server_id)
          {:ok, channel}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
    end
  end

  @doc """
  Joins a public server and auto-joins all current server channels.
  """
  def join_server(server_id, user_id) do
    case Repo.get(Server, server_id) do
      nil ->
        {:error, :not_found}

      %Server{is_public: false} ->
        {:error, :not_public}

      %Server{} ->
        Repo.transaction(fn ->
          with {:ok, member} <- do_add_member(server_id, user_id, "member"),
               :ok <- add_user_to_all_server_channels(server_id, user_id) do
            {:ok, member}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, {:ok, member}} ->
            Federation.maybe_push_for_server(server_id)
            {:ok, member}

          {:ok, other} ->
            other

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_create_channel(server_id, creator_id, attrs) do
    next_position = next_channel_position(server_id)

    channel_attrs =
      attrs
      |> Map.take([:name, :description, :avatar_url, :channel_topic, :channel_position])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.put(:creator_id, creator_id)
      |> Map.put(:server_id, server_id)
      |> Map.put(:is_public, false)
      |> Map.put_new(:name, "general")
      |> Map.put_new(:description, "Default server channel")
      |> Map.put_new(:channel_position, next_position)

    with {:ok, channel} <-
           %Conversation{}
           |> Conversation.channel_changeset(channel_attrs)
           |> Repo.insert(),
         :ok <- add_all_server_members_to_channel(server_id, channel.id) do
      {:ok, channel}
    end
  end

  defp next_channel_position(server_id) do
    from(c in Conversation,
      where: c.server_id == ^server_id and c.type == "channel",
      select: max(c.channel_position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp add_all_server_members_to_channel(server_id, channel_id) do
    user_ids =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and is_nil(sm.left_at),
        select: sm.user_id
      )
      |> Repo.all()

    Enum.reduce_while(user_ids, :ok, fn user_id, :ok ->
      case Conversations.add_member_to_conversation(channel_id, user_id, "member") do
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_user_to_all_server_channels(server_id, user_id) do
    channel_ids =
      from(c in Conversation,
        where: c.server_id == ^server_id and c.type == "channel",
        select: c.id
      )
      |> Repo.all()

    Enum.reduce_while(channel_ids, :ok, fn channel_id, :ok ->
      case Conversations.add_member_to_conversation(channel_id, user_id, "member") do
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp do_add_member(server_id, user_id, role) do
    existing_member =
      Repo.get_by(ServerMember, server_id: server_id, user_id: user_id)

    case existing_member do
      nil ->
        ServerMember.add_member_changeset(server_id, user_id, role)
        |> Repo.insert()
        |> case do
          {:ok, member} ->
            update_member_count(server_id)
            {:ok, member}

          {:error, reason} ->
            {:error, reason}
        end

      %ServerMember{left_at: nil} ->
        {:error, :already_member}

      member ->
        member
        |> ServerMember.changeset(%{
          left_at: nil,
          joined_at: DateTime.utc_now(),
          role: role
        })
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(server_id)
            {:ok, updated_member}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp update_member_count(server_id) do
    count =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and is_nil(sm.left_at),
        select: count()
      )
      |> Repo.one()

    from(s in Server, where: s.id == ^server_id)
    |> Repo.update_all(set: [member_count: count])
  end
end
