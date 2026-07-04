defmodule Elektrine.Messaging.ChannelCategories do
  @moduledoc """
  Context for channel categories inside community servers.

  Categories group a server's channels in the sidebar. All mutating functions
  require the acting user to hold the `manage_channels` permission on the
  server, which maps to the built-in `owner` and `admin` roles (see
  `Elektrine.Messaging.RoomACL` builtin role definitions).
  """

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    ChannelCategory,
    ChatConversation,
    Server,
    ServerMember
  }

  alias Elektrine.Repo

  # Built-in server roles that carry the `manage_channels` permission.
  @manage_channel_roles ["owner", "admin"]

  @doc """
  Lists a server's categories ordered by position (then id for stability).
  """
  def list_categories(server_id) when is_integer(server_id) do
    from(c in ChannelCategory,
      where: c.server_id == ^server_id,
      order_by: [asc: c.position, asc: c.id]
    )
    |> Repo.all()
  end

  def list_categories(_server_id), do: []

  @doc """
  Lists a server's categories with their channels preloaded.

  Returns `{categories, uncategorized_channels}` where categories are ordered
  by position and each category's channels (as well as the uncategorized
  list) are ordered by `channel_position`.
  """
  def list_categories_with_channels(server_id) when is_integer(server_id) do
    channel_query =
      from(conversation in ChatConversation,
        where: conversation.type == "channel",
        order_by: [asc: conversation.channel_position, asc: conversation.inserted_at]
      )

    categories =
      from(c in ChannelCategory,
        where: c.server_id == ^server_id,
        order_by: [asc: c.position, asc: c.id],
        preload: [channels: ^channel_query]
      )
      |> Repo.all()

    uncategorized =
      from(conversation in ChatConversation,
        where:
          conversation.server_id == ^server_id and conversation.type == "channel" and
            is_nil(conversation.category_id),
        order_by: [asc: conversation.channel_position, asc: conversation.inserted_at]
      )
      |> Repo.all()

    {categories, uncategorized}
  end

  @doc """
  Gets a category by id, or `nil`.
  """
  def get_category(category_id) when is_integer(category_id) do
    Repo.get(ChannelCategory, category_id)
  end

  def get_category(_category_id), do: nil

  @doc """
  Creates a category in a server. Requires `manage_channels`.
  """
  def create_category(server_id, user_id, attrs) when is_map(attrs) do
    with %Server{} <- Repo.get(Server, server_id),
         :ok <- authorize_manage_channels(server_id, user_id) do
      params = %{
        name: attrs[:name] || attrs["name"],
        position: attrs[:position] || attrs["position"] || next_category_position(server_id),
        server_id: server_id
      }

      %ChannelCategory{}
      |> ChannelCategory.changeset(params)
      |> Repo.insert()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renames a category. Requires `manage_channels` on the category's server.
  """
  def rename_category(category_id, user_id, name) do
    with %ChannelCategory{} = category <- get_category(category_id),
         :ok <- authorize_manage_channels(category.server_id, user_id) do
      category
      |> ChannelCategory.changeset(%{name: name})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a category. The category's channels are kept and their
  `category_id` is nullified. Requires `manage_channels`.
  """
  def delete_category(category_id, user_id) do
    with %ChannelCategory{} = category <- get_category(category_id),
         :ok <- authorize_manage_channels(category.server_id, user_id) do
      Repo.transaction(fn ->
        from(conversation in ChatConversation, where: conversation.category_id == ^category.id)
        |> Repo.update_all(set: [category_id: nil])

        case Repo.delete(category) do
          {:ok, deleted} -> deleted
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reorders a server's categories to match the given list of category ids.
  Ids not belonging to the server are ignored; categories missing from the
  list keep their relative order after the reordered ones.
  Requires `manage_channels`.
  """
  def reorder_categories(server_id, user_id, ordered_ids) when is_list(ordered_ids) do
    with :ok <- authorize_manage_channels(server_id, user_id) do
      categories = list_categories(server_id)
      categories_by_id = Map.new(categories, &{&1.id, &1})

      listed = Enum.filter(ordered_ids, &Map.has_key?(categories_by_id, &1))
      missing = Enum.map(categories, & &1.id) -- listed

      (listed ++ missing)
      |> Enum.with_index()
      |> Enum.each(fn {category_id, position} ->
        from(c in ChannelCategory, where: c.id == ^category_id)
        |> Repo.update_all(set: [position: position])
      end)

      {:ok, list_categories(server_id)}
    end
  end

  @doc """
  Assigns a channel to a category (or clears the assignment when
  `category_id` is `nil`). The category must belong to the channel's server.
  Requires `manage_channels`.
  """
  def assign_channel_to_category(channel_id, user_id, category_id) do
    with %ChatConversation{type: "channel", server_id: server_id} = channel
         when is_integer(server_id) <- Repo.get(ChatConversation, channel_id),
         :ok <- authorize_manage_channels(server_id, user_id),
         {:ok, resolved_category_id} <- resolve_category_for_server(category_id, server_id) do
      channel
      |> ChatConversation.changeset(%{category_id: resolved_category_id})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      %ChatConversation{} -> {:error, :not_a_server_channel}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates that `category_id` (possibly `nil`) references a category of the
  given server. Returns `{:ok, category_id | nil}` or
  `{:error, :category_not_in_server}`.
  """
  def resolve_category_for_server(nil, _server_id), do: {:ok, nil}

  def resolve_category_for_server(category_id, server_id) when is_integer(category_id) do
    case get_category(category_id) do
      %ChannelCategory{server_id: ^server_id} -> {:ok, category_id}
      _ -> {:error, :category_not_in_server}
    end
  end

  def resolve_category_for_server(_category_id, _server_id),
    do: {:error, :category_not_in_server}

  defp authorize_manage_channels(server_id, user_id)
       when is_integer(server_id) and is_integer(user_id) do
    member =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at)
      )
      |> Repo.one()

    case member do
      %ServerMember{role: role} when role in @manage_channel_roles -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_manage_channels(_server_id, _user_id), do: {:error, :unauthorized}

  defp next_category_position(server_id) do
    from(c in ChannelCategory,
      where: c.server_id == ^server_id,
      select: max(c.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end
end
