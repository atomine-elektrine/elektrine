defmodule ElektrineWeb.Admin.CommunitiesController do
  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, params) do
    page = SafeConvert.parse_page(params)
    per_page = 30
    search = Map.get(params, "search", "")
    category_filter = Map.get(params, "category", "all")
    status_filter = Map.get(params, "status", "all")

    # Base query for counting (without group_by)
    count_query =
      from(c in Elektrine.Messaging.Conversation,
        where: c.type == "community"
      )

    # Apply filters to count query
    count_query =
      if search != "" do
        search_pattern = "%#{search}%"

        from(c in count_query,
          where: ilike(c.name, ^search_pattern) or ilike(c.description, ^search_pattern)
        )
      else
        count_query
      end

    count_query =
      if category_filter != "all" do
        from(c in count_query, where: c.community_category == ^category_filter)
      else
        count_query
      end

    count_query =
      if status_filter == "public" do
        from(c in count_query, where: c.is_public == true)
      else
        if status_filter == "private" do
          from(c in count_query, where: c.is_public == false)
        else
          count_query
        end
      end

    # Get total count
    total_count = Repo.aggregate(count_query, :count, :id)

    # Base query with message counts for display
    base_query =
      from(c in Elektrine.Messaging.Conversation,
        where: c.type == "community",
        left_join: m in Elektrine.Messaging.Message,
        on: m.conversation_id == c.id and is_nil(m.deleted_at),
        group_by: c.id,
        select: %{
          id: c.id,
          name: c.name,
          description: c.description,
          is_public: c.is_public,
          member_count: c.member_count,
          community_category: c.community_category,
          creator_id: c.creator_id,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at,
          last_message_at: c.last_message_at,
          post_count: count(m.id)
        }
      )

    # Apply same filters to display query
    query =
      if search != "" do
        search_pattern = "%#{search}%"

        from(c in base_query,
          where: ilike(c.name, ^search_pattern) or ilike(c.description, ^search_pattern)
        )
      else
        base_query
      end

    query =
      if category_filter != "all" do
        from(c in query, where: c.community_category == ^category_filter)
      else
        query
      end

    query =
      if status_filter == "public" do
        from(c in query, where: c.is_public == true)
      else
        if status_filter == "private" do
          from(c in query, where: c.is_public == false)
        else
          query
        end
      end

    # Get communities with creators
    communities =
      query
      |> order_by([c], desc: c.member_count, desc: c.updated_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Enum.map(fn community_data ->
        creator =
          if community_data.creator_id do
            Repo.get(Accounts.User, community_data.creator_id)
          else
            nil
          end

        Map.put(community_data, :creator, creator)
      end)

    # Get category counts for filter
    category_counts =
      from(c in Elektrine.Messaging.Conversation,
        where: c.type == "community",
        group_by: c.community_category,
        select: {c.community_category, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Get overall stats
    stats = %{
      total: total_count,
      public:
        from(c in Elektrine.Messaging.Conversation,
          where: c.type == "community" and c.is_public == true
        )
        |> Repo.aggregate(:count),
      private:
        from(c in Elektrine.Messaging.Conversation,
          where: c.type == "community" and c.is_public == false
        )
        |> Repo.aggregate(:count),
      active_7d:
        from(c in Elektrine.Messaging.Conversation,
          where: c.type == "community" and c.last_message_at > ago(7, "day")
        )
        |> Repo.aggregate(:count)
    }

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :communities,
      communities: communities,
      current_page: page,
      total_pages: total_pages,
      page_range: page_range,
      search_query: search,
      category_filter: category_filter,
      status_filter: status_filter,
      category_counts: category_counts,
      stats: stats,
      total_count: total_count
    )
  end

  def show(conn, %{"id" => id} = params) do
    community =
      Repo.get!(Elektrine.Messaging.Conversation, id)
      |> Repo.preload([:creator])

    # Pagination for members
    members_page = SafeConvert.parse_page(params, "members_page", 1)
    members_per_page = 50

    # Get members with their roles
    members_query =
      from(cm in Elektrine.Messaging.ConversationMember,
        where: cm.conversation_id == ^id and is_nil(cm.left_at),
        join: u in Accounts.User,
        on: cm.user_id == u.id,
        select: %{
          id: cm.id,
          user_id: u.id,
          username: u.username,
          handle: u.handle,
          role: cm.role,
          joined_at: cm.inserted_at
        },
        order_by: [
          fragment(
            "CASE ? WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 WHEN 'moderator' THEN 3 ELSE 4 END",
            cm.role
          ),
          asc: cm.inserted_at
        ]
      )

    total_members = Repo.aggregate(members_query, :count)

    members =
      members_query
      |> limit(^members_per_page)
      |> offset(^((members_page - 1) * members_per_page))
      |> Repo.all()

    members_total_pages = ceil(total_members / members_per_page)
    members_page_range = pagination_range(members_page, members_total_pages)

    # Pagination for posts
    posts_page = SafeConvert.parse_page(params, "posts_page", 1)
    posts_per_page = 20

    # Get posts with pagination
    posts_query =
      from(m in Elektrine.Messaging.Message,
        where: m.conversation_id == ^id and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at]
      )

    total_posts = Repo.aggregate(posts_query, :count)

    recent_posts =
      posts_query
      |> limit(^posts_per_page)
      |> offset(^((posts_page - 1) * posts_per_page))
      |> preload(:sender)
      |> Repo.all()
      |> Elektrine.Messaging.Message.decrypt_messages()
      |> Enum.map(fn m ->
        %{
          id: m.id,
          title: m.title,
          content: m.content,
          username: m.sender.username,
          handle: m.sender.handle,
          sender_id: m.sender_id,
          inserted_at: m.inserted_at,
          upvotes: m.upvotes,
          downvotes: m.downvotes,
          reply_count: m.reply_count
        }
      end)

    posts_total_pages = ceil(total_posts / posts_per_page)
    posts_page_range = pagination_range(posts_page, posts_total_pages)

    # Get community stats
    stats = %{
      total_posts: total_posts,
      total_members: total_members,
      posts_7d:
        from(m in Elektrine.Messaging.Message,
          where:
            m.conversation_id == ^id and is_nil(m.deleted_at) and m.inserted_at > ago(7, "day")
        )
        |> Repo.aggregate(:count),
      posts_30d:
        from(m in Elektrine.Messaging.Message,
          where:
            m.conversation_id == ^id and is_nil(m.deleted_at) and m.inserted_at > ago(30, "day")
        )
        |> Repo.aggregate(:count)
    }

    render(conn, :show_community,
      community: community,
      members: members,
      members_page: members_page,
      members_total_pages: members_total_pages,
      members_page_range: members_page_range,
      recent_posts: recent_posts,
      posts_page: posts_page,
      posts_total_pages: posts_total_pages,
      posts_page_range: posts_page_range,
      stats: stats
    )
  end

  def delete(conn, %{"id" => id}) do
    community = Repo.get!(Elektrine.Messaging.Conversation, id)

    # Count what will be deleted for the confirmation message
    message_count =
      from(m in Elektrine.Messaging.Message, where: m.conversation_id == ^id)
      |> Repo.aggregate(:count, :id)

    member_count =
      from(cm in Elektrine.Messaging.ConversationMember,
        where: cm.conversation_id == ^id and is_nil(cm.left_at)
      )
      |> Repo.aggregate(:count, :id)

    flair_count =
      from(f in Elektrine.Messaging.CommunityFlair, where: f.community_id == ^id)
      |> Repo.aggregate(:count, :id)

    # Delete all community flairs
    from(f in Elektrine.Messaging.CommunityFlair, where: f.community_id == ^id)
    |> Repo.delete_all()

    # Delete all messages in the community (includes posts, discussions, and replies)
    from(m in Elektrine.Messaging.Message, where: m.conversation_id == ^id)
    |> Repo.delete_all()

    # Delete all members
    from(cm in Elektrine.Messaging.ConversationMember, where: cm.conversation_id == ^id)
    |> Repo.delete_all()

    # Delete the community itself
    Repo.delete!(community)

    conn
    |> put_flash(
      :info,
      "Community '#{community.name}' has been deleted (#{message_count} posts/messages, #{member_count} members, #{flair_count} flairs)"
    )
    |> redirect(to: ~p"/pripyat/communities")
  end

  def toggle(conn, %{"id" => id}) do
    community = Repo.get!(Elektrine.Messaging.Conversation, id)

    # Toggle enabled status (using is_public as enabled flag for now)
    changeset =
      Ecto.Changeset.change(community, %{
        is_public: !community.is_public
      })

    updated_community = Repo.update!(changeset)

    status = if updated_community.is_public, do: "enabled", else: "disabled"

    conn
    |> put_flash(:info, "Community '#{community.name}' has been #{status}")
    |> redirect(to: ~p"/pripyat/communities/#{id}")
  end

  def remove_member(conn, %{"id" => id} = params) do
    user_id = params["user_id"]
    community = Repo.get!(Elektrine.Messaging.Conversation, id)

    # Find and update the member record
    member =
      Repo.get_by!(Elektrine.Messaging.ConversationMember,
        conversation_id: id,
        user_id: user_id
      )

    changeset =
      Ecto.Changeset.change(member, %{
        left_at: DateTime.utc_now()
      })

    Repo.update!(changeset)

    # Update member count
    new_count =
      from(cm in Elektrine.Messaging.ConversationMember,
        where: cm.conversation_id == ^id and is_nil(cm.left_at)
      )
      |> Repo.aggregate(:count, :id)

    Ecto.Changeset.change(community, %{member_count: new_count})
    |> Repo.update!()

    conn
    |> put_flash(:info, "Member has been removed from the community")
    |> redirect(to: ~p"/pripyat/communities/#{id}")
  end

  # Helper for pagination
  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..max(total_pages, 1) |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        Enum.to_list(1..5) ++ [:gap, total_pages]

      current_page >= total_pages - 3 ->
        [1, :gap] ++ Enum.to_list((total_pages - 4)..total_pages)

      true ->
        [1, :gap] ++ Enum.to_list((current_page - 1)..(current_page + 1)) ++ [:gap, total_pages]
    end
  end
end
