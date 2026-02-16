defmodule ElektrineWeb.Admin.MailboxesController do
  @moduledoc """
  Controller for admin mailbox management including listing, deleting mailboxes,
  and mailbox integrity checks.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Email, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone, do: current_user.timezone, else: "Etc/UTC"

    time_format =
      if current_user && current_user.time_format, do: current_user.time_format, else: "12"

    conn
    |> assign(:timezone, timezone)
    |> assign(:time_format, time_format)
  end

  def index(conn, params) do
    search_query = Map.get(params, "search", "")
    page = SafeConvert.parse_page(params)
    per_page = 20

    {mailboxes, total_count} =
      if search_query != "" do
        search_mailboxes_paginated(search_query, page, per_page)
      else
        get_all_mailboxes_paginated(page, per_page)
      end

    total_pages = ceil(total_count / per_page)

    page_range = pagination_range(page, total_pages)

    render(conn, :mailboxes,
      mailboxes: mailboxes,
      search_query: search_query,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def delete(conn, %{"id" => id}) do
    case Email.get_mailbox_admin(id) do
      nil ->
        conn
        |> put_flash(:error, "Mailbox not found.")
        |> redirect(to: ~p"/pripyat/mailboxes")

      mailbox ->
        case Email.delete_mailbox(mailbox) do
          {:ok, _} ->
            conn
            |> put_flash(:info, "Successfully deleted mailbox #{mailbox.email}.")
            |> redirect(to: ~p"/pripyat/mailboxes")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Failed to delete mailbox #{mailbox.email}.")
            |> redirect(to: ~p"/pripyat/mailboxes")
        end
    end
  end

  # Private helper functions

  defp get_all_mailboxes_paginated(page, per_page) do
    offset = (page - 1) * per_page

    query =
      from(m in Email.Mailbox,
        order_by: [desc: m.inserted_at],
        select: %{
          id: m.id,
          email: m.email,
          username: m.username,
          user_id: m.user_id,
          orphaned: is_nil(m.user_id),
          inserted_at: m.inserted_at
        }
      )

    # Get total count but multiply by 2 since each mailbox represents 2 email addresses
    base_count = Repo.aggregate(Email.Mailbox, :count, :id)
    total_count = base_count * 2

    base_mailboxes =
      query
      # Get half the requested amount since we'll expand each
      |> limit(^div(per_page + 1, 2))
      |> offset(^div(offset, 2))
      |> Repo.all()

    # Expand each mailbox into both domain addresses
    expanded_mailboxes = expand_mailboxes_to_domains(base_mailboxes)

    # Take only the requested amount
    mailboxes = Enum.take(expanded_mailboxes, per_page)

    {mailboxes, total_count}
  end

  defp search_mailboxes_paginated(search_query, page, per_page) do
    offset = (page - 1) * per_page
    search_term = "%#{search_query}%"

    # Search for mailboxes where either the stored email, username, or potential domain addresses match
    query =
      from(m in Email.Mailbox,
        where:
          ilike(m.email, ^search_term) or
            ilike(m.username, ^search_term) or
            ilike(fragment("? || '@elektrine.com'", m.username), ^search_term) or
            ilike(fragment("? || '@z.org'", m.username), ^search_term),
        order_by: [desc: m.inserted_at],
        select: %{
          id: m.id,
          email: m.email,
          username: m.username,
          user_id: m.user_id,
          orphaned: is_nil(m.user_id),
          inserted_at: m.inserted_at
        }
      )

    base_count =
      from(m in Email.Mailbox,
        where:
          ilike(m.email, ^search_term) or
            ilike(m.username, ^search_term) or
            ilike(fragment("? || '@elektrine.com'", m.username), ^search_term) or
            ilike(fragment("? || '@z.org'", m.username), ^search_term)
      )
      |> Repo.aggregate(:count, :id)

    # Multiply by 2 since each mailbox represents 2 addresses
    total_count = base_count * 2

    base_mailboxes =
      query
      |> limit(^div(per_page + 1, 2))
      |> offset(^div(offset, 2))
      |> Repo.all()

    # Expand each mailbox into both domain addresses and filter by search term
    expanded_mailboxes =
      base_mailboxes
      |> expand_mailboxes_to_domains()
      |> Enum.filter(fn mailbox ->
        String.contains?(
          String.downcase(mailbox.email),
          String.downcase(String.trim(search_query))
        ) ||
          String.contains?(
            String.downcase(mailbox.username || ""),
            String.downcase(String.trim(search_query))
          )
      end)

    mailboxes = Enum.take(expanded_mailboxes, per_page)

    {mailboxes, total_count}
  end

  # Helper function to expand mailboxes to show both domain addresses
  defp expand_mailboxes_to_domains(mailboxes) do
    Enum.flat_map(mailboxes, fn mailbox ->
      if mailbox.username do
        [
          # elektrine.com address
          %{
            id: mailbox.id,
            email: "#{mailbox.username}@elektrine.com",
            username: mailbox.username,
            user_id: mailbox.user_id,
            orphaned: mailbox.orphaned,
            inserted_at: mailbox.inserted_at
          },
          # z.org address
          %{
            id: mailbox.id,
            email: "#{mailbox.username}@z.org",
            username: mailbox.username,
            user_id: mailbox.user_id,
            orphaned: mailbox.orphaned,
            inserted_at: mailbox.inserted_at
          }
        ]
      else
        # Fallback for mailboxes without username (legacy)
        [mailbox]
      end
    end)
  end

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages//1 |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        1..7//1 |> Enum.to_list()

      current_page >= total_pages - 3 ->
        (total_pages - 6)..total_pages//1 |> Enum.to_list()

      true ->
        (current_page - 3)..(current_page + 3)//1 |> Enum.to_list()
    end
  end

  # Mailbox integrity checks

  def integrity(conn, _params) do
    # System Integrity Checks

    # 1. Users without handles (new namespace issue)
    users_without_handles =
      from(u in Accounts.User,
        where: is_nil(u.handle) or u.handle == "",
        select: %{
          user_id: u.id,
          username: u.username,
          inserted_at: u.inserted_at
        }
      )
      |> Repo.all()

    # 2. Users without unique_id
    users_without_unique_id =
      from(u in Accounts.User,
        where: is_nil(u.unique_id) or u.unique_id == "",
        select: %{
          user_id: u.id,
          username: u.username,
          handle: u.handle,
          inserted_at: u.inserted_at
        }
      )
      |> Repo.all()

    # 3. Duplicate handles (case-insensitive)
    duplicate_handles =
      from(u in Accounts.User,
        where: not is_nil(u.handle),
        select: %{
          handle: u.handle,
          handle_lower: fragment("lower(?)", u.handle),
          user_id: u.id,
          username: u.username,
          inserted_at: u.inserted_at
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.handle_lower)
      |> Enum.filter(fn {_handle, users} -> length(users) > 1 end)
      |> Enum.map(fn {handle_lower, users} ->
        %{
          handle: handle_lower,
          duplicate_count: length(users),
          users: Enum.sort_by(users, & &1.inserted_at)
        }
      end)

    # 4. Duplicate usernames (case-insensitive)
    duplicate_usernames =
      from(u in Accounts.User,
        where: not is_nil(u.username),
        select: %{
          username: u.username,
          username_lower: fragment("lower(?)", u.username),
          user_id: u.id,
          handle: u.handle,
          recovery_email: u.recovery_email,
          inserted_at: u.inserted_at,
          last_login_at: u.last_login_at
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.username_lower)
      |> Enum.filter(fn {_username, users} -> length(users) > 1 end)
      |> Enum.map(fn {username_lower, users} ->
        %{
          username: username_lower,
          duplicate_count: length(users),
          users: Enum.sort_by(users, & &1.inserted_at)
        }
      end)

    # 5. Find users with multiple mailboxes
    duplicate_mailboxes =
      from(m in Email.Mailbox,
        group_by: m.user_id,
        having: count(m.id) > 1,
        select: %{
          user_id: m.user_id,
          count: count(m.id)
        }
      )
      |> Repo.all()

    # Find users with username/email mismatches
    mismatched_mailboxes =
      from(m in Email.Mailbox,
        join: u in Accounts.User,
        on: m.user_id == u.id,
        where: fragment("? != ? || '@elektrine.com'", m.email, u.username),
        select: %{
          user_id: m.user_id,
          username: u.username,
          mailbox_email: m.email,
          mailbox_id: m.id
        }
      )
      |> Repo.all()

    # Find users without any mailbox
    users_without_mailboxes =
      from(u in Accounts.User,
        left_join: m in Email.Mailbox,
        on: m.user_id == u.id,
        where: is_nil(m.id),
        select: %{
          user_id: u.id,
          username: u.username,
          recovery_email: u.recovery_email,
          inserted_at: u.inserted_at
        }
      )
      |> Repo.all()

    # Find duplicate mailboxes by email (case-insensitive)
    duplicate_emails =
      from(m in Email.Mailbox,
        left_join: u in Accounts.User,
        on: m.user_id == u.id,
        select: %{
          email: m.email,
          email_lower: fragment("lower(?)", m.email),
          mailbox_id: m.id,
          user_id: m.user_id,
          username: u.username,
          inserted_at: m.inserted_at,
          message_count:
            fragment("(SELECT COUNT(*) FROM email_messages WHERE mailbox_id = ?)", m.id)
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.email_lower)
      |> Enum.filter(fn {_email, boxes} -> length(boxes) > 1 end)
      |> Enum.map(fn {email_lower, boxes} ->
        %{
          email: email_lower,
          duplicate_count: length(boxes),
          mailboxes: Enum.sort_by(boxes, & &1.message_count, :desc)
        }
      end)
      |> Enum.sort_by(& &1.duplicate_count, :desc)

    # Get detailed info for each problematic user
    integrity_issues =
      duplicate_mailboxes
      |> Enum.filter(fn %{user_id: user_id} -> not is_nil(user_id) end)
      |> Enum.map(fn %{user_id: user_id, count: count} ->
        try do
          user = Accounts.get_user!(user_id)

          mailboxes =
            from(m in Email.Mailbox,
              where: m.user_id == ^user_id,
              order_by: [asc: m.inserted_at]
            )
            |> Repo.all()

          %{
            user: user,
            user_id: user_id,
            mailbox_count: count,
            mailboxes: mailboxes,
            orphaned: false
          }
        rescue
          Ecto.NoResultsError ->
            mailboxes =
              from(m in Email.Mailbox,
                where: m.user_id == ^user_id,
                order_by: [asc: m.inserted_at]
              )
              |> Repo.all()

            %{
              user: nil,
              user_id: user_id,
              mailbox_count: count,
              mailboxes: mailboxes,
              orphaned: true
            }
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Process username/email mismatches
    mismatch_issues =
      Enum.map(mismatched_mailboxes, fn mismatch ->
        try do
          user = Accounts.get_user!(mismatch.user_id)
          mailbox = Email.get_mailbox_admin(mismatch.mailbox_id)

          %{
            type: :mismatch,
            user: user,
            user_id: user.id,
            mailbox: mailbox,
            expected_email: "#{user.username}@elektrine.com",
            current_email: mismatch.mailbox_email,
            orphaned: false
          }
        rescue
          Ecto.NoResultsError ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Process users without mailboxes
    missing_mailbox_issues =
      Enum.map(users_without_mailboxes, fn user_data ->
        try do
          user = Accounts.get_user!(user_data.user_id)

          %{
            type: :missing_mailbox,
            user: user,
            user_id: user.id,
            username: user.username,
            recovery_email: user.recovery_email,
            registered_at: user.inserted_at,
            expected_email: "#{user.username}@elektrine.com",
            orphaned: false
          }
        rescue
          Ecto.NoResultsError ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Get summary statistics
    user_count = Repo.aggregate(Accounts.User, :count, :id)
    mailbox_count = Repo.aggregate(Email.Mailbox, :count, :id)

    # Combine all issues
    all_issues = integrity_issues ++ mismatch_issues ++ missing_mailbox_issues

    # Count total integrity problems
    total_integrity_issues =
      length(users_without_handles) +
        length(users_without_unique_id) +
        length(duplicate_handles) +
        length(duplicate_usernames) +
        length(duplicate_emails) +
        length(all_issues)

    render(conn, :mailbox_integrity,
      users_without_handles: users_without_handles,
      users_without_unique_id: users_without_unique_id,
      duplicate_handles: duplicate_handles,
      duplicate_usernames: duplicate_usernames,
      integrity_issues: integrity_issues,
      mismatch_issues: mismatch_issues,
      missing_mailbox_issues: missing_mailbox_issues,
      duplicate_emails: duplicate_emails,
      all_issues: all_issues,
      user_count: user_count,
      mailbox_count: mailbox_count,
      total_integrity_issues: total_integrity_issues
    )
  end

  def fix_integrity(conn, %{"user_id" => user_id, "action" => action} = params) do
    admin = conn.assigns.current_user
    _user = Accounts.get_user!(user_id)

    case action do
      "merge_mailboxes" ->
        merge_user_mailboxes(user_id, admin, conn)

      "delete_duplicates" ->
        delete_duplicate_mailboxes(user_id, admin, conn)

      "fix_mismatch" ->
        fix_username_email_mismatch(user_id, admin, conn)

      "create_mailbox" ->
        create_missing_mailbox(user_id, admin, conn)

      "merge_duplicate_email" ->
        merge_duplicate_email_mailboxes(
          params["mailbox_id"],
          params["target_mailbox_id"],
          admin,
          conn
        )

      "delete_duplicate_email" ->
        delete_duplicate_email_mailbox(params["mailbox_id"], admin, conn)

      _ ->
        conn
        |> put_flash(:error, "Invalid action")
        |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  end

  defp merge_user_mailboxes(user_id, admin, conn) do
    mailboxes =
      from(m in Email.Mailbox,
        where: m.user_id == ^user_id,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()

    case mailboxes do
      [primary | duplicates] ->
        Enum.each(duplicates, fn duplicate ->
          from(msg in Email.Message,
            where: msg.mailbox_id == ^duplicate.id
          )
          |> Repo.update_all(set: [mailbox_id: primary.id])

          Repo.delete(duplicate)
        end)

        Elektrine.AuditLog.log(
          admin.id,
          "merge_mailboxes",
          "mailbox_integrity",
          target_user_id: user_id,
          details: %{
            primary_mailbox_id: primary.id,
            merged_mailbox_ids: Enum.map(duplicates, & &1.id),
            total_merged: length(duplicates)
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(
          :info,
          "Merged #{length(duplicates)} duplicate mailboxes for user #{user_id}"
        )
        |> redirect(to: ~p"/pripyat/mailbox-integrity")

      [] ->
        conn
        |> put_flash(:error, "No mailboxes found for user #{user_id}")
        |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  rescue
    error ->
      conn
      |> put_flash(:error, "Failed to merge mailboxes: #{inspect(error)}")
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
  end

  defp delete_duplicate_mailboxes(user_id, admin, conn) do
    mailboxes =
      from(m in Email.Mailbox,
        where: m.user_id == ^user_id,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()

    case mailboxes do
      [_primary | duplicates] when duplicates != [] ->
        Enum.each(duplicates, fn duplicate ->
          from(msg in Email.Message,
            where: msg.mailbox_id == ^duplicate.id
          )
          |> Repo.delete_all()

          Repo.delete(duplicate)
        end)

        Elektrine.AuditLog.log(
          admin.id,
          "delete_duplicate_mailboxes",
          "mailbox_integrity",
          target_user_id: user_id,
          details: %{
            deleted_mailbox_ids: Enum.map(duplicates, & &1.id),
            total_deleted: length(duplicates)
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(
          :info,
          "Deleted #{length(duplicates)} duplicate mailboxes for user #{user_id}"
        )
        |> redirect(to: ~p"/pripyat/mailbox-integrity")

      _ ->
        conn
        |> put_flash(:info, "No duplicate mailboxes found for user #{user_id}")
        |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  rescue
    error ->
      conn
      |> put_flash(:error, "Failed to delete duplicate mailboxes: #{inspect(error)}")
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
  end

  defp fix_username_email_mismatch(user_id, admin, conn) do
    user = Accounts.get_user!(user_id)
    mailbox = Email.get_user_mailbox(user_id)

    if mailbox do
      expected_email = "#{user.username}@elektrine.com"

      case Email.update_mailbox_email(mailbox, expected_email) do
        {:ok, _updated_mailbox} ->
          Elektrine.AuditLog.log(
            admin.id,
            "fix_username_mismatch",
            "mailbox_integrity",
            target_user_id: user_id,
            details: %{
              old_email: mailbox.email,
              new_email: expected_email,
              username: user.username
            },
            ip_address: get_remote_ip(conn),
            user_agent: get_req_header(conn, "user-agent") |> List.first()
          )

          conn
          |> put_flash(
            :info,
            "Fixed mailbox email for #{user.username}: #{mailbox.email} -> #{expected_email}"
          )
          |> redirect(to: ~p"/pripyat/mailbox-integrity")

        {:error, reason} ->
          conn
          |> put_flash(
            :error,
            "Failed to fix mailbox email for #{user.username}: #{inspect(reason)}"
          )
          |> redirect(to: ~p"/pripyat/mailbox-integrity")
      end
    else
      conn
      |> put_flash(:error, "No mailbox found for user #{user.username}")
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  rescue
    error ->
      conn
      |> put_flash(:error, "Failed to fix username mismatch: #{inspect(error)}")
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
  end

  defp create_missing_mailbox(user_id, admin, conn) do
    try do
      user = Accounts.get_user!(user_id)

      case Email.create_mailbox(user) do
        {:ok, mailbox} ->
          Elektrine.AuditLog.log(
            admin.id,
            "create_missing_mailbox",
            "mailbox",
            target_user_id: user.id,
            details: %{
              created_email: mailbox.email,
              username: user.username
            },
            ip_address: get_remote_ip(conn),
            user_agent: get_req_header(conn, "user-agent") |> List.first()
          )

          conn
          |> put_flash(:info, "Created missing mailbox for #{user.username}: #{mailbox.email}")
          |> redirect(to: ~p"/pripyat/mailbox-integrity")

        {:error, reason} ->
          conn
          |> put_flash(
            :error,
            "Failed to create mailbox for #{user.username}: #{inspect(reason)}"
          )
          |> redirect(to: ~p"/pripyat/mailbox-integrity")
      end
    rescue
      error ->
        conn
        |> put_flash(:error, "Failed to create missing mailbox: #{inspect(error)}")
        |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  end

  defp merge_duplicate_email_mailboxes(mailbox_id, target_mailbox_id, admin, conn) do
    mailbox_id = SafeConvert.to_integer!(mailbox_id, mailbox_id)
    target_mailbox_id = SafeConvert.to_integer!(target_mailbox_id, target_mailbox_id)

    source_mailbox = Repo.get!(Email.Mailbox, mailbox_id)
    target_mailbox = Repo.get!(Email.Mailbox, target_mailbox_id)

    message_count =
      from(m in Email.Message, where: m.mailbox_id == ^mailbox_id)
      |> Repo.aggregate(:count, :id)

    from(m in Email.Message, where: m.mailbox_id == ^mailbox_id)
    |> Repo.update_all(set: [mailbox_id: target_mailbox_id])

    source_user_id = source_mailbox.user_id
    target_user_id = target_mailbox.user_id

    alias_conflicts = []
    aliases_moved = 0

    if source_user_id && target_user_id && source_user_id != target_user_id do
      source_aliases = from(a in Email.Alias, where: a.user_id == ^source_user_id) |> Repo.all()
      target_aliases = from(a in Email.Alias, where: a.user_id == ^target_user_id) |> Repo.all()

      target_alias_emails =
        target_aliases |> Enum.map(&String.downcase(&1.alias_email)) |> MapSet.new()

      for source_alias <- source_aliases do
        if MapSet.member?(target_alias_emails, String.downcase(source_alias.alias_email)) do
          Repo.delete!(source_alias)
          _alias_conflicts = [source_alias.alias_email | alias_conflicts]
        else
          source_alias
          |> Ecto.Changeset.change(user_id: target_user_id)
          |> Repo.update!()

          _aliases_moved = aliases_moved + 1
        end
      end
    end

    source_user =
      if source_mailbox.user_id, do: Accounts.get_user!(source_mailbox.user_id), else: nil

    Repo.delete!(source_mailbox)

    if source_user do
      other_mailboxes =
        from(m in Email.Mailbox, where: m.user_id == ^source_user.id)
        |> Repo.aggregate(:count, :id)

      if other_mailboxes == 0 do
        Repo.delete!(source_user)
      end
    end

    if target_mailbox.user_id do
      target_user = Accounts.get_user!(target_mailbox.user_id)

      if target_user.username != String.downcase(target_user.username) do
        old_username = target_user.username
        new_username = String.downcase(target_user.username)

        target_user
        |> Ecto.Changeset.change(username: new_username)
        |> Repo.update!()

        target_mailbox
        |> Ecto.Changeset.change(email: "#{new_username}@elektrine.com")
        |> Repo.update!()

        Elektrine.AuditLog.log(
          admin.id,
          "normalize_username",
          "user",
          target_user_id: target_user.id,
          details: %{
            old_username: old_username,
            new_username: new_username,
            reason: "Case normalization during duplicate merge"
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )
      end
    end

    Elektrine.AuditLog.log(
      admin.id,
      "merge_duplicate_email_mailboxes",
      "mailbox",
      details: %{
        source_mailbox_id: mailbox_id,
        source_email: source_mailbox.email,
        source_user_deleted: source_user != nil,
        target_mailbox_id: target_mailbox_id,
        target_email: target_mailbox.email,
        target_username_normalized: target_mailbox.user_id != nil,
        messages_moved: message_count,
        aliases_moved: aliases_moved,
        alias_conflicts: alias_conflicts
      },
      ip_address: get_remote_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )

    source_username = if source_user, do: source_user.username, else: "unknown"

    target_username =
      if target_mailbox.user_id do
        target_user = Accounts.get_user!(target_mailbox.user_id)
        target_user.username
      else
        "unknown"
      end

    flash_message =
      if source_user do
        if alias_conflicts != [] do
          "Successfully merged user '#{source_username}' into '#{String.downcase(target_username)}': #{message_count} messages moved, #{aliases_moved} aliases transferred (#{length(alias_conflicts)} conflicts resolved), user '#{source_username}' deleted"
        else
          "Successfully merged user '#{source_username}' into '#{String.downcase(target_username)}': #{message_count} messages moved, #{aliases_moved} aliases transferred, user '#{source_username}' deleted"
        end
      else
        "Merged orphaned mailbox: #{message_count} messages moved to '#{String.downcase(target_username)}'"
      end

    conn
    |> put_flash(:info, flash_message)
    |> redirect(to: ~p"/pripyat/mailbox-integrity")
  end

  defp delete_duplicate_email_mailbox(mailbox_id, admin, conn) do
    mailbox_id = SafeConvert.to_integer!(mailbox_id, mailbox_id)
    mailbox = Repo.get!(Email.Mailbox, mailbox_id)

    message_count =
      from(m in Email.Message, where: m.mailbox_id == ^mailbox_id)
      |> Repo.aggregate(:count, :id)

    from(m in Email.Message, where: m.mailbox_id == ^mailbox_id)
    |> Repo.delete_all()

    user_deleted =
      if mailbox.user_id do
        user = Accounts.get_user!(mailbox.user_id)

        alias_count =
          from(a in Email.Alias, where: a.user_id == ^user.id)
          |> Repo.aggregate(:count, :id)

        from(a in Email.Alias, where: a.user_id == ^user.id)
        |> Repo.delete_all()

        Repo.delete!(mailbox)
        Repo.delete!(user)

        Elektrine.AuditLog.log(
          admin.id,
          "delete_duplicate_user",
          "user",
          target_user_id: user.id,
          details: %{
            username: user.username,
            reason: "Duplicate user (case sensitivity issue)",
            mailbox_deleted: mailbox.email,
            messages_deleted: message_count,
            aliases_deleted: alias_count
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        {true, user.username, alias_count}
      else
        Repo.delete!(mailbox)
        {false, nil, 0}
      end

    Elektrine.AuditLog.log(
      admin.id,
      "delete_duplicate_user_complete",
      "user",
      details: %{
        mailbox_id: mailbox_id,
        email: mailbox.email,
        messages_deleted: message_count,
        user_deleted: user_deleted,
        username_deleted: elem(user_deleted, 1),
        aliases_deleted: elem(user_deleted, 2)
      },
      ip_address: get_remote_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )

    if elem(user_deleted, 0) do
      conn
      |> put_flash(
        :info,
        "Successfully deleted duplicate user '#{elem(user_deleted, 1)}': #{message_count} messages, #{elem(user_deleted, 2)} aliases, and all associated data removed"
      )
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
    else
      conn
      |> put_flash(
        :info,
        "Deleted orphaned mailbox #{mailbox.email} and #{message_count} messages"
      )
      |> redirect(to: ~p"/pripyat/mailbox-integrity")
    end
  end

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end
end
