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
  alias Elektrine.{AuditLog, Notifications}
  alias Elektrine.Repo

  @doc """
  Perform a global search across all accessible data for a user
  """
  def global_search(user, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    scopes = Keyword.get(opts, :scopes, []) |> normalize_scopes()
    strict_scopes? = Keyword.get(opts, :enforce_scopes, false)

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
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:social"], fn ->
            search_people(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:chat"], fn ->
            search_chat_messages(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:social"], fn ->
            search_timeline_posts(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:social"], fn ->
            search_discussions(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:social"], fn ->
            search_communities(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:social"], fn ->
            search_federated_posts(search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:email"], fn ->
            search_emails(user, search_term, limit)
          end)
          |> maybe_append_search_results(scopes, strict_scopes?, ["read:email"], fn ->
            search_files(user, search_term, limit)
          end)
        end

      results = results ++ search_settings(command_query, limit, scopes, strict_scopes?)
      results = results ++ search_actions(command_query, limit, scopes, strict_scopes?)

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

  defp search_settings(query, limit, scopes, strict_scopes?) do
    query = normalize_command_query(query)

    if scope_allowed?(scopes, strict_scopes?, ["read:account"]) do
      setting_entries()
      |> Enum.filter(&entry_matches?(&1, query))
      |> Enum.take(max(div(limit, 6), 4))
    else
      []
    end
  end

  defp search_actions(query, limit, scopes, strict_scopes?) do
    query = normalize_command_query(query)

    list_actions(scopes: scopes, enforce_scopes: strict_scopes?)
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

  @doc """
  Lists command palette actions, optionally filtered by PAT scopes.
  """
  def list_actions(opts \\ []) do
    scopes = Keyword.get(opts, :scopes, []) |> normalize_scopes()
    strict_scopes? = Keyword.get(opts, :enforce_scopes, false)

    action_entries()
    |> Enum.filter(&action_allowed?(&1, scopes, strict_scopes?))
    |> Enum.sort_by(&(-&1.relevance))
  end

  @doc """
  Executes a command palette action.

  Supports command strings (for example `>open chat`) and action ids.
  """
  def execute_action(user, command_or_id, opts \\ [])

  def execute_action(nil, _command_or_id, _opts), do: {:error, :unauthorized}

  def execute_action(user, command_or_id, opts) do
    normalized = normalize_command_query(command_or_id)

    if normalized == "" do
      {:error, :unknown_action}
    else
      scopes = Keyword.get(opts, :scopes, []) |> normalize_scopes()
      strict_scopes? = Keyword.get(opts, :enforce_scopes, false)

      case resolve_action(normalized) do
        nil ->
          {:error, :unknown_action}

        action ->
          if action_allowed?(action, scopes, strict_scopes?) do
            result = run_action(user, action)
            audit_action_execution(user, action, result, opts)
            result
          else
            {:error, :insufficient_scope}
          end
      end
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

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_scopes(_), do: MapSet.new()

  defp maybe_append_search_results(results, scopes, strict_scopes?, required_scopes, fun)
       when is_list(results) and is_list(required_scopes) and is_function(fun, 0) do
    if scope_allowed?(scopes, strict_scopes?, required_scopes) do
      results ++ fun.()
    else
      results
    end
  end

  defp scope_allowed?(scopes, strict_scopes?, required_scopes) do
    cond do
      required_scopes == [] ->
        true

      not strict_scopes? and MapSet.size(scopes) == 0 ->
        true

      true ->
        Enum.any?(required_scopes, &MapSet.member?(scopes, &1))
    end
  end

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
        command: "compose email",
        aliases: ["new email", "send email"],
        execution: :navigate,
        required_scopes: ["write:email"],
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
        command: "open chat",
        aliases: ["chat"],
        execution: :navigate,
        required_scopes: ["read:chat"],
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
        command: "open notifications",
        aliases: ["notifications", "alerts"],
        execution: :navigate,
        required_scopes: ["read:account"],
        content: "Review unread alerts",
        url: "/notifications",
        updated_at: DateTime.utc_now(),
        relevance: 1.06,
        keywords: ["alerts", "notifications", "activity"]
      },
      %{
        id: "action_mark_all_notifications_read",
        type: "action",
        title: "Mark Notifications Read",
        command: "mark notifications read",
        aliases: ["clear notifications", "read all notifications"],
        execution: :operation,
        operation: :mark_notifications_read,
        required_scopes: ["write:account"],
        content: "Mark all notifications as read",
        url: "/notifications",
        updated_at: DateTime.utc_now(),
        relevance: 1.05,
        keywords: ["notification", "read", "clear", "inbox zero"]
      },
      %{
        id: "action_open_vpn",
        type: "action",
        title: "Open VPN",
        command: "open vpn",
        aliases: ["vpn"],
        execution: :navigate,
        required_scopes: ["read:account"],
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
        command: "open overview",
        aliases: ["overview", "home"],
        execution: :navigate,
        required_scopes: ["read:account"],
        content: "Go back to your home dashboard",
        url: "/overview",
        updated_at: DateTime.utc_now(),
        relevance: 1.02,
        keywords: ["overview", "home", "dashboard"]
      }
    ]
  end

  defp resolve_action(normalized_command) do
    action_entries()
    |> Enum.find(fn action ->
      action_commands =
        [action[:id], action[:command], action[:title]]
        |> Kernel.++(action[:aliases] || [])
        |> Enum.map(&normalize_command_query/1)

      normalized_command in action_commands
    end)
  end

  defp action_allowed?(action, scopes, strict_scopes?) do
    required_scopes = action[:required_scopes] || []

    cond do
      required_scopes == [] ->
        true

      not strict_scopes? and MapSet.size(scopes) == 0 ->
        true

      true ->
        Enum.all?(required_scopes, &MapSet.member?(scopes, &1))
    end
  end

  defp run_action(_user, %{execution: :navigate} = action) do
    {:ok,
     %{
       action_id: action.id,
       mode: :navigate,
       url: action.url,
       message: action.content
     }}
  end

  defp run_action(user, %{execution: :operation, operation: :mark_notifications_read} = action) do
    :ok = Notifications.mark_all_as_read(user.id)

    {:ok,
     %{
       action_id: action.id,
       mode: :operation,
       message: "Marked all notifications as read",
       url: action.url
     }}
  end

  defp run_action(_user, _action), do: {:error, :unknown_action}

  defp audit_action_execution(user, action, result, opts) do
    status =
      case result do
        {:ok, _} -> "ok"
        {:error, reason} -> "error:#{reason}"
      end

    _ =
      AuditLog.log(user.id, "search_action.execute", "search_action",
        details: %{
          action_id: action.id,
          command: action[:command],
          mode: to_string(action[:execution]),
          status: status,
          source: opts[:source] || "search"
        },
        ip_address: opts[:ip_address],
        user_agent: opts[:user_agent]
      )

    :ok
  rescue
    _ -> :ok
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
      if is_map(attachment) do
        attachment["filename"] || attachment[:filename] || attachment["name"] ||
          attachment[:name]
      else
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
