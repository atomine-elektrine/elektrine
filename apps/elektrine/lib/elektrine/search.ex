defmodule Elektrine.Search do
  @moduledoc """
  Global search functionality with access control.

  Searches across all user-accessible data including:
  - People
  - Chat conversations and messages
  - Timeline posts and replies
  - Discussion threads and posts
  - Email messages and mailboxes
  - Email attachments and files
  - Settings and command actions

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

    safe_query = sanitize_search_term(query)
    trimmed_query = String.trim(safe_query)
    command_mode = String.starts_with?(trimmed_query, ">")
    command_query = normalize_command_query(trimmed_query)

    if !command_mode && String.length(trimmed_query) < 2 do
      %{results: [], total_count: 0}
    else
      search_term = "%#{trimmed_query}%"

      results = []

      results =
        if command_mode do
          results
        else
          results
          |> Kernel.++(search_people(user, search_term, limit))
          |> Kernel.++(search_chat_messages(user, search_term, limit))
          |> Kernel.++(search_timeline_posts(user, search_term, limit))
          |> Kernel.++(search_discussions(user, search_term, limit))
          |> Kernel.++(search_communities(user, search_term, limit))
          |> Kernel.++(search_federated_posts(search_term, limit))
          |> Kernel.++(search_emails(user, search_term, limit))
          |> Kernel.++(search_files(user, search_term, limit))
        end

      results = results ++ search_settings(command_query, limit)
      results = results ++ search_actions(command_query, limit)

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

  defp search_people(user, search_term, limit) do
    from(u in Elektrine.Accounts.User,
      where:
        u.id != ^user.id and
          (ilike(u.username, ^search_term) or ilike(u.display_name, ^search_term) or
             ilike(u.handle, ^search_term)),
      select: %{
        id: u.id,
        type: "person",
        username: u.username,
        display_name: u.display_name,
        handle: u.handle,
        updated_at: u.updated_at,
        relevance: 0.95
      },
      limit: ^max(div(limit, 8), 3),
      order_by: [desc: u.updated_at]
    )
    |> Repo.all()
    |> Enum.map(fn result ->
      username = result.username || "user"
      handle = result.handle || username

      display_name =
        if is_binary(result.display_name), do: String.trim(result.display_name), else: ""

      title =
        if display_name == "" do
          "@#{username}"
        else
          display_name
        end

      %{
        id: result.id,
        type: "person",
        title: title,
        content: "@#{handle}",
        url: "/#{handle}",
        updated_at: result.updated_at,
        relevance: result.relevance
      }
    end)
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

  defp search_files(user, search_term, limit) do
    from(m in Elektrine.Email.Message,
      join: mb in Elektrine.Email.Mailbox,
      on: m.mailbox_id == mb.id,
      where:
        mb.user_id == ^user.id and
          m.has_attachments == true and
          m.deleted == false and
          (ilike(m.subject, ^search_term) or ilike(m.from, ^search_term) or
             fragment("CAST(? AS text) ILIKE ?", m.attachments, ^search_term)),
      select: %{
        id: m.id,
        type: "file",
        subject: m.subject,
        from: m.from,
        attachments: m.attachments,
        updated_at: m.inserted_at,
        relevance: 0.72
      },
      limit: ^max(div(limit, 8), 3),
      order_by: [desc: m.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn result ->
      attachment_name = first_attachment_name(result.attachments)
      subject = if is_binary(result.subject), do: String.trim(result.subject), else: ""
      from = if is_binary(result.from), do: String.trim(result.from), else: "Unknown sender"

      title =
        cond do
          attachment_name != nil -> attachment_name
          subject != "" -> subject
          true -> "Email attachment"
        end

      %{
        id: result.id,
        type: "file",
        title: title,
        content: "File in email from #{from}",
        url: "/email/view/#{result.id}",
        updated_at: result.updated_at,
        relevance: result.relevance
      }
    end)
  end

  defp search_settings(query, limit) do
    query = normalize_command_query(query)

    setting_entries()
    |> Enum.filter(&entry_matches?(&1, query))
    |> Enum.take(max(div(limit, 6), 4))
  end

  defp search_actions(query, limit) do
    query = normalize_command_query(query)

    action_entries()
    |> Enum.filter(&entry_matches?(&1, query))
    |> Enum.take(max(div(limit, 6), 4))
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
      trimmed_query = String.trim(safe_query)
      search_term = "#{trimmed_query}%"

      if String.starts_with?(trimmed_query, ">") do
        action_entries()
        |> Enum.filter(&entry_matches?(&1, normalize_command_query(trimmed_query)))
        |> Enum.take(limit)
        |> Enum.map(fn action -> %{text: action.title, type: "action"} end)
      else
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

        people =
          from(u in Elektrine.Accounts.User,
            where:
              u.id != ^user.id and
                (ilike(u.username, ^search_term) or ilike(u.display_name, ^search_term) or
                   ilike(u.handle, ^search_term)),
            select: %{text: fragment("CONCAT('@', ?)", u.username), type: "person"},
            limit: ^max(div(limit, 2), 2)
          )
          |> Repo.all()

        commands =
          (action_entries() ++ setting_entries())
          |> Enum.filter(&entry_matches?(&1, normalize_command_query(trimmed_query)))
          |> Enum.take(max(div(limit, 2), 2))
          |> Enum.map(fn entry -> %{text: entry.title, type: entry.type} end)

        (people ++ commands ++ email_domains)
        |> Enum.uniq_by(&String.downcase(to_string(&1.text)))
        |> Enum.take(limit)
      end
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

  defp normalize_command_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.trim_leading(">")
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_command_query(_), do: ""

  defp entry_matches?(_entry, ""), do: true

  defp entry_matches?(entry, query) do
    haystack =
      [entry.title, entry.content, Enum.join(entry.keywords || [], " ")]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, query)
  end

  defp action_entries do
    [
      %{
        id: "action_compose_email",
        type: "action",
        title: "Compose Email",
        content: "Start a new email message",
        url: "/email/compose?return_to=search",
        updated_at: DateTime.utc_now(),
        relevance: 1.1,
        keywords: ["compose", "email", "send", "message"]
      },
      %{
        id: "action_open_chat",
        type: "action",
        title: "Open Chat",
        content: "Jump into your conversations",
        url: "/chat",
        updated_at: DateTime.utc_now(),
        relevance: 1.08,
        keywords: ["chat", "dm", "message", "conversation"]
      },
      %{
        id: "action_open_notifications",
        type: "action",
        title: "Open Notifications",
        content: "Review unread alerts",
        url: "/notifications",
        updated_at: DateTime.utc_now(),
        relevance: 1.06,
        keywords: ["alerts", "notifications", "activity"]
      },
      %{
        id: "action_open_vpn",
        type: "action",
        title: "Open VPN",
        content: "Manage your WireGuard profiles",
        url: "/vpn",
        updated_at: DateTime.utc_now(),
        relevance: 1.04,
        keywords: ["vpn", "wireguard", "security", "network"]
      },
      %{
        id: "action_open_overview",
        type: "action",
        title: "Open Overview",
        content: "Go back to your home dashboard",
        url: "/overview",
        updated_at: DateTime.utc_now(),
        relevance: 1.02,
        keywords: ["overview", "home", "dashboard"]
      }
    ]
  end

  defp setting_entries do
    [
      %{
        id: "settings_profile",
        type: "settings",
        title: "Profile Settings",
        content: "Edit your profile, avatar, and bio",
        url: "/account/profile/edit",
        updated_at: DateTime.utc_now(),
        relevance: 1.03,
        keywords: ["profile", "avatar", "bio", "display name"]
      },
      %{
        id: "settings_security",
        type: "settings",
        title: "Security Settings",
        content: "Manage password and security options",
        url: "/account/password",
        updated_at: DateTime.utc_now(),
        relevance: 1.01,
        keywords: ["security", "password", "account", "login"]
      },
      %{
        id: "settings_two_factor",
        type: "settings",
        title: "Two-Factor Authentication",
        content: "Set up and manage 2FA",
        url: "/account/two_factor",
        updated_at: DateTime.utc_now(),
        relevance: 1.0,
        keywords: ["2fa", "two factor", "authenticator", "security"]
      },
      %{
        id: "settings_passkeys",
        type: "settings",
        title: "Passkeys",
        content: "Manage WebAuthn passkeys",
        url: "/account/passkeys",
        updated_at: DateTime.utc_now(),
        relevance: 0.99,
        keywords: ["passkey", "webauthn", "security"]
      },
      %{
        id: "settings_email",
        type: "settings",
        title: "Email Settings",
        content: "Configure signatures, aliases, and inbox behavior",
        url: "/email/settings",
        updated_at: DateTime.utc_now(),
        relevance: 0.98,
        keywords: ["email", "signature", "alias", "filters"]
      },
      %{
        id: "settings_storage",
        type: "settings",
        title: "Storage",
        content: "View usage and storage limits",
        url: "/account/storage",
        updated_at: DateTime.utc_now(),
        relevance: 0.97,
        keywords: ["storage", "quota", "usage", "space"]
      }
    ]
  end

  defp first_attachment_name(attachments) when is_map(attachments) do
    attachments
    |> Map.values()
    |> Enum.find_value(fn attachment ->
      cond do
        is_map(attachment) ->
          attachment["filename"] || attachment[:filename] || attachment["name"] ||
            attachment[:name]

        true ->
          nil
      end
    end)
    |> case do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp first_attachment_name(_), do: nil

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
