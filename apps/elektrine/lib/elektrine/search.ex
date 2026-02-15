defmodule Elektrine.Search do
  @moduledoc """
  Global search functionality with access control.

  Searches across all user-accessible data including:
  - Chat conversations and messages
  - Timeline posts and replies
  - Discussion threads and posts
  - Email messages and mailboxes

  SECURITY: All search functions enforce proper authorization:
  - Chat: Only messages in conversations where user is an active member
  - Timeline: Respects visibility settings (public/followers-only/private)
  - Discussions: Only public discussions or private ones where user is a member
  - Email: Only emails in mailboxes owned by the user
  - Deleted content is never searchable
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  @doc """
  Perform a global search across all accessible data for a user
  """
  def global_search(user, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    if String.length(String.trim(query)) < 2 do
      %{results: [], total_count: 0}
    else
      # Sanitize search term to prevent LIKE pattern injection
      safe_query = sanitize_search_term(query)
      search_term = "%#{String.trim(safe_query)}%"

      results = []

      # Search social platform content
      results = results ++ search_chat_messages(user, search_term, limit)
      results = results ++ search_timeline_posts(user, search_term, limit)
      results = results ++ search_discussions(user, search_term, limit)
      results = results ++ search_communities(user, search_term, limit)
      results = results ++ search_federated_posts(search_term, limit)

      # Search emails
      results = results ++ search_emails(user, search_term, limit)

      # Sort by relevance and limit results
      sorted_results =
        results
        |> Enum.sort_by(&(-&1.relevance))
        |> Enum.take(limit)

      %{
        results: sorted_results,
        total_count: length(results)
      }
    end
  end

  # Search chat messages - ONLY messages in conversations the user is a member of
  defp search_chat_messages(user, search_term, limit) do
    # Extract keywords and hash them for blind index search
    keywords = Elektrine.Encryption.extract_keywords(search_term)

    if Enum.empty?(keywords) do
      []
    else
      keyword_hashes =
        Enum.map(keywords, fn kw ->
          Elektrine.Encryption.hash_keyword(kw, user.id)
        end)

      from(m in Elektrine.Messaging.Message,
        join: cm in Elektrine.Messaging.ConversationMember,
        on: cm.conversation_id == m.conversation_id,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        # User must be an active member
        # Don't search deleted messages
        where:
          cm.user_id == ^user.id and
            is_nil(cm.left_at) and
            c.type in ["dm", "group", "channel"] and
            fragment("? && ?", m.search_index, ^keyword_hashes) and
            is_nil(m.deleted_at),
        select: %{
          id: m.id,
          type: "chat",
          title:
            fragment("CASE WHEN ? IS NOT NULL THEN ? ELSE 'Chat Message' END", c.name, c.name),
          content: "Chat message",
          url: fragment("CONCAT(?, ?)", "/chat/", c.hash),
          updated_at: m.inserted_at,
          relevance: 0.9,
          sender_id: m.sender_id
        },
        limit: ^div(limit, 9),
        order_by: [desc: m.inserted_at]
      )
      |> Repo.all()
      |> decrypt_message_content(user.id)
    end
  end

  # Search timeline posts - respect visibility settings
  defp search_timeline_posts(user, search_term, limit) do
    # Extract keywords and hash them for blind index search
    keywords = Elektrine.Encryption.extract_keywords(search_term)

    if Enum.empty?(keywords) do
      []
    else
      keyword_hashes =
        Enum.map(keywords, fn kw ->
          Elektrine.Encryption.hash_keyword(kw, user.id)
        end)

      from(m in Elektrine.Messaging.Message,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        left_join: u in Elektrine.Accounts.User,
        on: u.id == m.sender_id,
        left_join: f in Elektrine.Profiles.Follow,
        on: f.follower_id == ^user.id and f.followed_id == m.sender_id,
        # Don't search deleted posts
        # Public posts are visible to all
        # Followers-only posts require following
        # Users can see their own posts
        where:
          c.type == "timeline" and
            m.post_type == "post" and
            is_nil(m.deleted_at) and
            (m.visibility == "public" or
               (m.visibility == "followers" and not is_nil(f.id)) or
               m.sender_id == ^user.id) and
            (fragment("? && ?", m.search_index, ^keyword_hashes) or
               (not is_nil(m.title) and ilike(m.title, ^search_term))),
        select: %{
          id: m.id,
          type: "timeline",
          title:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN ? ELSE CONCAT('@', ?) END",
              m.title,
              m.title,
              u.username
            ),
          content: "Timeline post",
          url: fragment("CONCAT(?, ?)", "/timeline/post/", m.id),
          updated_at: m.inserted_at,
          relevance: 0.85,
          sender_id: m.sender_id
        },
        limit: ^div(limit, 9),
        order_by: [desc: m.inserted_at]
      )
      |> Repo.all()
      |> decrypt_message_content(user.id)
    end
  end

  # Search discussion posts - only in communities the user has access to
  defp search_discussions(user, search_term, limit) do
    # Extract keywords and hash them for blind index search
    keywords = Elektrine.Encryption.extract_keywords(search_term)

    if Enum.empty?(keywords) do
      []
    else
      keyword_hashes =
        Enum.map(keywords, fn kw ->
          Elektrine.Encryption.hash_keyword(kw, user.id)
        end)

      from(m in Elektrine.Messaging.Message,
        join: c in Elektrine.Messaging.Conversation,
        on: c.id == m.conversation_id,
        left_join: cm in Elektrine.Messaging.ConversationMember,
        on: cm.conversation_id == c.id and cm.user_id == ^user.id,
        # Don't search deleted posts
        # Public discussions are visible to all
        # Private discussions require membership
        where:
          c.type == "community" and
            is_nil(m.deleted_at) and
            (c.is_public == true or
               (c.is_public == false and not is_nil(cm.id) and is_nil(cm.left_at))) and
            (fragment("? && ?", m.search_index, ^keyword_hashes) or
               (not is_nil(m.title) and ilike(m.title, ^search_term)) or
               ilike(c.name, ^search_term)),
        select: %{
          id: m.id,
          type: "discussion",
          title: fragment("CASE WHEN ? IS NOT NULL THEN ? ELSE ? END", m.title, m.title, c.name),
          content: "Discussion post",
          url: fragment("CONCAT('/discussions/', ?, '/post/', ?)", c.id, m.id),
          updated_at: m.inserted_at,
          relevance: 0.8,
          sender_id: m.sender_id
        },
        limit: ^div(limit, 9),
        order_by: [desc: m.inserted_at]
      )
      |> Repo.all()
      |> decrypt_message_content(user.id)
    end
  end

  # Search communities - only public communities or ones user is a member of
  defp search_communities(user, search_term, limit) do
    from(c in Elektrine.Messaging.Conversation,
      left_join: cm in Elektrine.Messaging.ConversationMember,
      on: cm.conversation_id == c.id and cm.user_id == ^user.id,
      where:
        c.type == "community" and
          (c.is_public == true or not is_nil(cm.id)) and
          (ilike(c.name, ^search_term) or
             ilike(c.description, ^search_term)),
      select: %{
        id: c.id,
        type: "community",
        title: c.name,
        content: c.description,
        url: fragment("CONCAT(?, ?)", "/discussions/", c.name),
        updated_at: c.updated_at,
        relevance: 0.8
      },
      limit: ^div(limit, 10),
      order_by: [desc: c.member_count]
    )
    |> Repo.all()
  end

  # Search federated posts from remote instances
  # These are public posts received via ActivityPub, not encrypted
  defp search_federated_posts(search_term, limit) do
    from(m in Elektrine.Messaging.Message,
      left_join: a in Elektrine.ActivityPub.Actor,
      on: a.id == m.remote_actor_id,
      where:
        m.federated == true and
          m.visibility in ["public", "unlisted"] and
          is_nil(m.deleted_at) and
          (ilike(m.content, ^search_term) or
             (not is_nil(m.title) and ilike(m.title, ^search_term)) or
             (not is_nil(a.display_name) and ilike(a.display_name, ^search_term)) or
             (not is_nil(a.username) and ilike(a.username, ^search_term))),
      select: %{
        id: m.id,
        type: "federated",
        title: fragment("COALESCE(?, CONCAT('@', ?, '@', ?))", m.title, a.username, a.domain),
        content: fragment("LEFT(?, 200)", m.content),
        updated_at: m.inserted_at,
        relevance: 0.75,
        actor_username: a.username,
        actor_domain: a.domain,
        actor_display_name: a.display_name,
        activitypub_id: m.activitypub_id
      },
      limit: ^div(limit, 8),
      order_by: [desc: m.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn result ->
      # Construct URL with properly encoded activitypub_id
      url =
        if result.activitypub_id do
          "/remote/post/#{URI.encode_www_form(result.activitypub_id)}"
        else
          "/timeline/post/#{result.id}"
        end

      Map.put(result, :url, url)
    end)
  end

  # Search email messages and mailboxes
  defp search_emails(user, search_term, limit) do
    # Extract keywords and hash them for blind index search
    keywords = Elektrine.Encryption.extract_keywords(search_term)

    # Search user's email messages
    messages =
      if Enum.empty?(keywords) do
        []
      else
        keyword_hashes =
          Enum.map(keywords, fn kw ->
            Elektrine.Encryption.hash_keyword(kw, user.id)
          end)

        from(m in Elektrine.Email.Message,
          join: mb in Elektrine.Email.Mailbox,
          on: m.mailbox_id == mb.id,
          where:
            mb.user_id == ^user.id and
              (ilike(m.subject, ^search_term) or
                 ilike(m.from, ^search_term) or
                 ilike(m.to, ^search_term) or
                 fragment("? && ?", m.search_index, ^keyword_hashes)),
          select: %{
            id: m.id,
            type: "email",
            title: m.subject,
            content: "Email message",
            url: fragment("CONCAT(?, ?)", "/email/view/", m.id),
            updated_at: m.inserted_at,
            relevance: 0.8,
            mailbox_id: m.mailbox_id
          },
          limit: ^div(limit, 6)
        )
        |> Repo.all()
        |> decrypt_email_content(user.id)
      end

    # Search user's mailboxes
    mailboxes =
      from(mb in Elektrine.Email.Mailbox,
        where:
          mb.user_id == ^user.id and
            ilike(mb.email, ^search_term),
        select: %{
          id: mb.id,
          type: "mailbox",
          title: mb.email,
          content: "Email mailbox",
          url: "/email",
          updated_at: mb.inserted_at,
          relevance: 0.9
        },
        limit: ^div(limit, 6)
      )
      |> Repo.all()

    messages ++ mailboxes
  end

  @doc """
  Get search suggestions based on partial query
  """
  def get_suggestions(user, partial_query, limit \\ 10) do
    if String.length(String.trim(partial_query)) < 1 do
      []
    else
      # Sanitize search term to prevent LIKE pattern injection
      safe_query = sanitize_search_term(partial_query)
      search_term = "#{String.trim(safe_query)}%"

      # Suggest email domains
      email_domains =
        from(m in Elektrine.Email.Message,
          join: mb in Elektrine.Email.Mailbox,
          on: m.mailbox_id == mb.id,
          where:
            mb.user_id == ^user.id and
              ilike(m.from, ^search_term),
          select: %{
            text: fragment("SPLIT_PART(?, '@', 2)", m.from),
            type: "email_domain"
          },
          distinct: fragment("SPLIT_PART(?, '@', 2)", m.from),
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.filter(&(&1.text != ""))

      email_domains
    end
  end

  @doc """
  Search within a specific category with access control
  """
  def search_category(user, category, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    # Sanitize search term to prevent LIKE pattern injection
    safe_query = sanitize_search_term(query)
    search_term = "%#{String.trim(safe_query)}%"

    case category do
      "emails" -> search_emails(user, search_term, limit)
      _ -> []
    end
  end

  # Sanitize search terms to prevent LIKE pattern injection
  defp sanitize_search_term(term), do: Elektrine.TextHelpers.sanitize_search_term(term)

  # Decrypt message content for search results
  defp decrypt_message_content(results, _user_id) when is_list(results) do
    Enum.map(results, fn result ->
      if result[:id] && result[:sender_id] do
        # Fetch and decrypt the message
        case Repo.get(Elektrine.Messaging.Message, result.id) do
          nil ->
            result

          message ->
            decrypted = Elektrine.Messaging.Message.decrypt_content(message)
            # Update content with first 200 chars of decrypted content
            content =
              if decrypted.content do
                String.slice(decrypted.content, 0, 200)
              else
                result.content
              end

            Map.put(result, :content, content)
        end
      else
        result
      end
    end)
  end

  # Decrypt email content for search results
  defp decrypt_email_content(results, user_id) when is_list(results) do
    Enum.map(results, fn result ->
      if result[:id] && result[:mailbox_id] do
        # Fetch and decrypt the email
        case Repo.get(Elektrine.Email.Message, result.id) do
          nil ->
            result

          message ->
            decrypted = Elektrine.Email.Message.decrypt_content(message, user_id)
            # Update content with first 200 chars of decrypted content
            content =
              if decrypted.text_body do
                String.slice(decrypted.text_body, 0, 200)
              else
                result.content
              end

            Map.put(result, :content, content)
        end
      else
        result
      end
    end)
  end
end
