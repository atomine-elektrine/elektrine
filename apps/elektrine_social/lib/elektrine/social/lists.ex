defmodule Elektrine.Social.Lists do
  @moduledoc "Functions for managing user lists (curated collections of accounts to follow).\n"
  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{BlockedUsersCache, User, UserMute}
  alias Elektrine.ActivityPub.{Actor, Instance, UserBlock}
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.{Conversation, Message, TimelinePagination}
  alias Elektrine.Social.{List, ListMember}
  @doc "Creates a new list for a user.\n"
  def create_list(attrs \\ %{}) do
    %List{} |> List.changeset(attrs) |> Repo.insert()
  end

  @doc "Updates a list.\n"
  # SECURITY: This function trusts the caller to have verified ownership of the
  # given List. Callers MUST only pass a List that belongs to the acting user
  # (e.g. one fetched via get_user_list/2). Do not pass a list resolved from a
  # client-supplied id without an ownership check.
  def update_list(%List{} = list, attrs) do
    list |> List.changeset(attrs) |> Repo.update()
  end

  @doc "Deletes a list.\n"
  # SECURITY: This function trusts the caller to have verified ownership of the
  # given List. Callers MUST only pass a List that belongs to the acting user
  # (e.g. one fetched via get_user_list/2). Do not pass a list resolved from a
  # client-supplied id without an ownership check.
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

  @doc "Lists the current user's lists that contain an account."
  def list_user_lists_for_account(owner_user_id, %User{id: account_id}) do
    list_user_lists_for_member(owner_user_id, :user_id, account_id)
  end

  def list_user_lists_for_account(owner_user_id, %Actor{id: actor_id}) do
    list_user_lists_for_member(owner_user_id, :remote_actor_id, actor_id)
  end

  def list_user_lists_for_account(_owner_user_id, _account), do: []

  defp list_user_lists_for_member(owner_user_id, member_field, account_id) do
    from(l in List,
      join: lm in ListMember,
      on: lm.list_id == l.id,
      where: l.user_id == ^owner_user_id and field(lm, ^member_field) == ^account_id,
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
  # SECURITY: This arity does NOT verify list ownership. Prefer the owner-scoped
  # add_to_list/3 for any path driven by client-supplied input.
  def add_to_list(list_id, attrs) do
    %ListMember{} |> ListMember.changeset(Map.put(attrs, :list_id, list_id)) |> Repo.insert()
  end

  @doc "Adds a member to a list, verifying the list belongs to owner_user_id.\n"
  def add_to_list(owner_user_id, list_id, attrs) do
    if list_owned_by?(owner_user_id, list_id) do
      add_to_list(list_id, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Removes a member from a list.\n"
  # SECURITY: This arity does NOT verify list ownership. Prefer the owner-scoped
  # remove_from_list/2 for any path driven by client-supplied input.
  def remove_from_list(list_member_id) do
    case Repo.get(ListMember, list_member_id) do
      nil -> {:error, :not_found}
      list_member -> Repo.delete(list_member)
    end
  end

  @doc "Removes a member from a list, only when the list belongs to owner_user_id.\n"
  def remove_from_list(owner_user_id, list_member_id) do
    query =
      from(lm in ListMember,
        join: l in List,
        on: l.id == lm.list_id,
        where: lm.id == ^list_member_id and l.user_id == ^owner_user_id
      )

    case Repo.one(query) do
      nil -> {:error, :unauthorized}
      list_member -> Repo.delete(list_member)
    end
  end

  @doc "Adds local users and remote actors to a user-owned list."
  def add_accounts_to_list(owner_user_id, list_id, attrs) do
    case get_user_list(owner_user_id, list_id) do
      %List{} ->
        attrs
        |> normalize_account_member_attrs()
        |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, members} ->
          if list_member_exists?(list_id, attrs) do
            {:cont, {:ok, members}}
          else
            case add_to_list(list_id, attrs) do
              {:ok, member} ->
                {:cont, {:ok, [member | members]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
        end)

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Removes local users and remote actors from a user-owned list by account ids."
  def remove_accounts_from_list(owner_user_id, list_id, attrs) do
    case get_user_list(owner_user_id, list_id) do
      %List{} ->
        account_refs = normalize_account_member_attrs(attrs)

        Enum.each(account_refs, fn
          %{user_id: user_id} ->
            delete_list_member(list_id, :user_id, user_id)

          %{remote_actor_id: remote_actor_id} ->
            delete_list_member(list_id, :remote_actor_id, remote_actor_id)
        end)

        {:ok, :removed}

      nil ->
        {:error, :not_found}
    end
  end

  defp list_owned_by?(owner_user_id, list_id) do
    not is_nil(get_user_list(owner_user_id, list_id))
  end

  defp normalize_account_member_attrs(%{"account_ids" => account_ids})
       when is_list(account_ids) do
    Enum.flat_map(account_ids, &account_member_attr/1)
  end

  defp normalize_account_member_attrs(%{account_ids: account_ids}) when is_list(account_ids) do
    Enum.flat_map(account_ids, &account_member_attr/1)
  end

  defp normalize_account_member_attrs(%{"user_id" => user_id}), do: account_member_attr(user_id)
  defp normalize_account_member_attrs(%{user_id: user_id}), do: account_member_attr(user_id)

  defp normalize_account_member_attrs(%{"remote_actor_id" => remote_actor_id}),
    do: account_member_attr("remote:#{remote_actor_id}")

  defp normalize_account_member_attrs(%{remote_actor_id: remote_actor_id}),
    do: account_member_attr("remote:#{remote_actor_id}")

  defp normalize_account_member_attrs(_attrs), do: []

  defp account_member_attr("remote:" <> id) do
    case parse_positive_int(id) do
      {:ok, remote_actor_id} -> [%{remote_actor_id: remote_actor_id}]
      :error -> []
    end
  end

  defp account_member_attr(id) do
    case parse_positive_int(id) do
      {:ok, user_id} -> [%{user_id: user_id}]
      :error -> []
    end
  end

  defp parse_positive_int(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_positive_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_int(_id), do: :error

  defp list_member_exists?(list_id, %{user_id: user_id}),
    do:
      Repo.exists?(
        from(member in ListMember,
          where: member.list_id == ^list_id and member.user_id == ^user_id
        )
      )

  defp list_member_exists?(list_id, %{remote_actor_id: remote_actor_id}),
    do:
      Repo.exists?(
        from(member in ListMember,
          where: member.list_id == ^list_id and member.remote_actor_id == ^remote_actor_id
        )
      )

  defp delete_list_member(list_id, field, account_id) do
    from(member in ListMember,
      where: member.list_id == ^list_id and field(member, ^field) == ^account_id
    )
    |> Repo.delete_all()
  end

  @doc "Gets timeline posts from a list (posts from list members only).\n"
  def get_list_timeline(list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    pagination = TimelinePagination.opts(opts)
    viewer_id = Keyword.get(opts, :viewer_id)

    list_member_ids =
      from(lm in ListMember,
        where: lm.list_id == ^list_id,
        select: %{user_id: lm.user_id, remote_actor_id: lm.remote_actor_id}
      )
      |> Repo.all()

    local_user_ids = Enum.filter(list_member_ids, & &1.user_id) |> Enum.map(& &1.user_id)

    remote_actor_ids =
      Enum.filter(list_member_ids, & &1.remote_actor_id) |> Enum.map(& &1.remote_actor_id)

    blocked_user_ids =
      if viewer_id, do: BlockedUsersCache.get_all_blocked_user_ids(viewer_id), else: []

    following_user_ids = if viewer_id, do: [viewer_id | following_user_ids(viewer_id)], else: []
    following_remote_actor_ids = if viewer_id, do: following_remote_actor_ids(viewer_id), else: []
    local_visibility_filter = list_local_visibility_filter(viewer_id, following_user_ids)

    remote_visibility_filter =
      list_remote_visibility_filter(viewer_id, following_remote_actor_ids)

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
                m.is_draft != true and
                m.sender_id not in ^blocked_user_ids and
                (m.approval_status == "approved" or is_nil(m.approval_status)),
            where: ^local_visibility_filter,
            order_by: [desc: m.id],
            limit: ^limit,
            preload: [
              sender: [:profile],
              conversation: [],
              link_preview: [],
              hashtags: [],
              reply_to: [sender: [:profile]],
              shared_message: [
                sender: [:profile],
                conversation: [],
                remote_actor: [],
                link_preview: [],
                poll: [options: []]
              ],
              poll: [options: []]
            ]
          )

        query =
          query
          |> TimelinePagination.apply(pagination)
          |> apply_local_viewer_policy(viewer_id)

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
            where: m.is_draft != true,
            where: ^remote_visibility_filter,
            order_by: [desc: m.id],
            limit: ^limit,
            preload: [
              remote_actor: [],
              link_preview: [],
              hashtags: [],
              reply_to: [remote_actor: []],
              shared_message: [
                sender: [:profile],
                conversation: [],
                remote_actor: [],
                link_preview: [],
                poll: [options: []]
              ],
              poll: [options: []]
            ]
          )

        query =
          query
          |> TimelinePagination.apply(pagination)
          |> apply_remote_viewer_policy(viewer_id)

        Repo.all(query)
      end

    (local_posts ++ federated_posts) |> Enum.sort_by(& &1.id, :desc) |> Enum.take(limit)
  end

  defp list_local_visibility_filter(nil, _following_user_ids) do
    dynamic([m], m.visibility in ["public", "unlisted"])
  end

  defp list_local_visibility_filter(_viewer_id, following_user_ids) do
    dynamic(
      [m],
      m.visibility in ["public", "unlisted"] or
        (m.sender_id in ^following_user_ids and m.visibility == "followers")
    )
  end

  defp list_remote_visibility_filter(nil, _following_remote_actor_ids) do
    dynamic([m], m.visibility in ["public", "unlisted"])
  end

  defp list_remote_visibility_filter(_viewer_id, following_remote_actor_ids) do
    dynamic(
      [m],
      m.visibility in ["public", "unlisted"] or
        (m.remote_actor_id in ^following_remote_actor_ids and m.visibility == "followers")
    )
  end

  defp following_user_ids(user_id) do
    from(f in Follow,
      where: f.follower_id == ^user_id and not is_nil(f.followed_id),
      select: f.followed_id
    )
    |> Repo.all()
  end

  defp following_remote_actor_ids(user_id) do
    from(f in Follow,
      where: f.follower_id == ^user_id and not is_nil(f.remote_actor_id),
      select: f.remote_actor_id
    )
    |> Repo.all()
  end

  defp apply_local_viewer_policy(query, nil), do: query

  defp apply_local_viewer_policy(query, viewer_id) do
    from(m in query,
      left_join: mute in UserMute,
      on: mute.muter_id == ^viewer_id and mute.muted_id == m.sender_id,
      where: is_nil(mute.id)
    )
  end

  defp apply_remote_viewer_policy(query, viewer_id) do
    query
    |> apply_remote_actor_block_policy(viewer_id)
    |> apply_remote_domain_block_policy(viewer_id)
    |> exclude_blocked_instances()
  end

  defp apply_remote_actor_block_policy(query, nil), do: query

  defp apply_remote_actor_block_policy(query, viewer_id) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_remote_actor in UserBlock,
      on:
        blocked_remote_actor.user_id == ^viewer_id and
          blocked_remote_actor.block_type in ["user", "mute"] and
          blocked_remote_actor.blocked_uri == remote_actor.uri,
      where: is_nil(remote_actor.id) or is_nil(blocked_remote_actor.id)
    )
  end

  defp apply_remote_domain_block_policy(query, nil), do: query

  defp apply_remote_domain_block_policy(query, viewer_id) do
    from(m in query,
      left_join: remote_actor in assoc(m, :remote_actor),
      left_join: blocked_domain in UserBlock,
      on:
        blocked_domain.user_id == ^viewer_id and blocked_domain.block_type == "domain" and
          (fragment("lower(?)", blocked_domain.blocked_uri) ==
             fragment("lower(?)", remote_actor.domain) or
             fragment(
               "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
               blocked_domain.blocked_uri,
               remote_actor.domain,
               blocked_domain.blocked_uri
             )),
      where: is_nil(remote_actor.id) or is_nil(blocked_domain.id)
    )
  end

  defp exclude_blocked_instances(query) do
    if Repo.exists?(from(i in Instance, where: i.blocked == true)) do
      from(m in query,
        left_join: remote_actor in assoc(m, :remote_actor),
        left_join: blocked_instance in Instance,
        on:
          blocked_instance.blocked == true and
            (fragment("lower(?)", blocked_instance.domain) ==
               fragment("lower(?)", remote_actor.domain) or
               fragment(
                 "? LIKE '*.%' AND lower(?) LIKE ('%.' || substring(lower(?) from 3))",
                 blocked_instance.domain,
                 remote_actor.domain,
                 blocked_instance.domain
               )),
        where: is_nil(remote_actor.id) or is_nil(blocked_instance.id)
      )
    else
      query
    end
  end
end
