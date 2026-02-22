defmodule Elektrine.Social.Lists do
  @moduledoc "Functions for managing user lists (curated collections of accounts to follow).\n"
  import Ecto.Query, warn: false
  alias Elektrine.Messaging.{Conversation, Message}
  alias Elektrine.Repo
  alias Elektrine.Social.{List, ListMember}
  @doc "Creates a new list for a user.\n"
  def create_list(attrs \\ %{}) do
    %List{} |> List.changeset(attrs) |> Repo.insert()
  end

  @doc "Updates a list.\n"
  def update_list(%List{} = list, attrs) do
    list |> List.changeset(attrs) |> Repo.update()
  end

  @doc "Deletes a list.\n"
  def delete_list(%List{} = list) do
    Repo.delete(list)
  end

  @doc "Gets a single list by id.\n"
  def get_list(id) do
    Repo.get(List, id) |> Repo.preload(:list_members)
  end

  @doc "Gets a user's list by id (ensures ownership).\n"
  def get_user_list(user_id, list_id) do
    from(l in List,
      where: l.id == ^list_id and l.user_id == ^user_id,
      preload: [list_members: [:user, :remote_actor]]
    )
    |> Repo.one()
  end

  @doc "Lists all lists for a user.\n"
  def list_user_lists(user_id) do
    from(l in List,
      where: l.user_id == ^user_id,
      order_by: [asc: l.name],
      preload: [list_members: [:user, :remote_actor]]
    )
    |> Repo.all()
  end

  @doc "Gets all public lists (for discovery).\n"
  def list_public_lists(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(l in List,
      where: l.visibility == "public",
      order_by: [desc: l.updated_at],
      limit: ^limit,
      preload: [user: [:profile], list_members: [:user, :remote_actor]]
    )
    |> Repo.all()
  end

  @doc "Searches public lists by name or description.\n"
  def search_public_lists(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    search_term = "%#{query}%"

    from(l in List,
      where:
        l.visibility == "public" and
          (ilike(l.name, ^search_term) or ilike(l.description, ^search_term)),
      order_by: [desc: l.updated_at],
      limit: ^limit,
      preload: [user: [:profile], list_members: [:user, :remote_actor]]
    )
    |> Repo.all()
  end

  @doc "Gets a public list by id (doesn't require ownership).\n"
  def get_public_list(list_id) do
    from(l in List,
      where: l.id == ^list_id and l.visibility == "public",
      preload: [user: [:profile], list_members: [:user, :remote_actor]]
    )
    |> Repo.one()
  end

  @doc "Adds a user or remote actor to a list.\n"
  def add_to_list(list_id, attrs) do
    %ListMember{} |> ListMember.changeset(Map.put(attrs, :list_id, list_id)) |> Repo.insert()
  end

  @doc "Removes a member from a list.\n"
  def remove_from_list(list_member_id) do
    case Repo.get(ListMember, list_member_id) do
      nil -> {:error, :not_found}
      list_member -> Repo.delete(list_member)
    end
  end

  @doc "Gets timeline posts from a list (posts from list members only).\n"
  def get_list_timeline(list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    before_id = Keyword.get(opts, :before_id)

    list_member_ids =
      from(lm in ListMember,
        where: lm.list_id == ^list_id,
        select: %{user_id: lm.user_id, remote_actor_id: lm.remote_actor_id}
      )
      |> Repo.all()

    local_user_ids = Enum.filter(list_member_ids, & &1.user_id) |> Enum.map(& &1.user_id)

    remote_actor_ids =
      Enum.filter(list_member_ids, & &1.remote_actor_id) |> Enum.map(& &1.remote_actor_id)

    local_posts =
      if Enum.empty?(local_user_ids) do
        []
      else
        query =
          from(m in Message,
            join: c in Conversation,
            on: c.id == m.conversation_id,
            where:
              c.type == "timeline" and m.post_type == "post" and m.sender_id in ^local_user_ids and
                is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
                (m.approval_status == "approved" or is_nil(m.approval_status)),
            preload: [
              sender: [:profile],
              conversation: [],
              link_preview: [],
              hashtags: [],
              reply_to: [sender: [:profile]],
              shared_message: [sender: [:profile], conversation: []],
              poll: [options: []]
            ]
          )

        query =
          if before_id do
            from(m in query, where: m.id < ^before_id)
          else
            query
          end

        Repo.all(query)
      end

    federated_posts =
      if Enum.empty?(remote_actor_ids) do
        []
      else
        query =
          from(m in Message,
            where:
              m.federated == true and m.remote_actor_id in ^remote_actor_ids and
                is_nil(m.deleted_at) and is_nil(m.reply_to_id),
            preload: [
              remote_actor: [],
              link_preview: [],
              hashtags: [],
              reply_to: [remote_actor: []],
              poll: [options: []]
            ]
          )

        query =
          if before_id do
            from(m in query, where: m.id < ^before_id)
          else
            query
          end

        Repo.all(query)
      end

    (local_posts ++ federated_posts) |> Enum.sort_by(& &1.id, :desc) |> Enum.take(limit)
  end
end
