defmodule ElektrineWeb.Admin.AliasesController do
  @moduledoc """
  Controller for admin alias management including listing, toggling,
  and deleting email aliases.
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
    per_page = 50

    # Check for exact match syntax (wrapped in quotes)
    is_exact_match =
      String.starts_with?(search_query, "\"") && String.ends_with?(search_query, "\"")

    clean_query =
      if is_exact_match do
        String.trim(search_query, "\"")
      else
        search_query
      end

    # Build regular query for pagination
    query =
      from(a in Email.Alias,
        left_join: u in Accounts.User,
        on: a.user_id == u.id,
        left_join: m in Email.Mailbox,
        on: m.user_id == u.id,
        select: %{
          id: a.id,
          alias_address: a.alias_email,
          forward_to: a.target_email,
          enabled: a.enabled,
          created_at: a.inserted_at,
          mailbox_email: m.email,
          mailbox_id: m.id,
          username: u.username,
          user_id: u.id,
          alias_email_lower: fragment("lower(?)", a.alias_email)
        }
      )

    query =
      cond do
        clean_query == "" ->
          query

        is_exact_match ->
          # Exact match on any field
          from([a, u, m] in query,
            where:
              a.alias_email == ^clean_query or
                a.target_email == ^clean_query or
                m.email == ^clean_query or
                u.username == ^clean_query
          )

        true ->
          # Fuzzy match
          search_pattern = "%#{clean_query}%"

          from([a, u, m] in query,
            where:
              ilike(a.alias_email, ^search_pattern) or
                ilike(a.target_email, ^search_pattern) or
                ilike(m.email, ^search_pattern) or
                ilike(u.username, ^search_pattern)
          )
      end

    # Get total count for pagination
    total_count = Repo.aggregate(query, :count, :id)

    # Get paginated results
    aliases =
      query
      |> order_by([a, m, u], desc: a.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :aliases,
      aliases: aliases,
      search_query: search_query,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  def toggle(conn, %{"id" => id}) do
    alias_record = Repo.get!(Email.Alias, id)

    case Ecto.Changeset.change(alias_record, enabled: !alias_record.enabled) |> Repo.update() do
      {:ok, updated_alias} ->
        action = if updated_alias.enabled, do: "enabled", else: "disabled"

        # Log the action
        Elektrine.AuditLog.log(
          conn.assigns.current_user.id,
          "toggle_alias",
          "alias",
          details: %{
            alias_id: updated_alias.id,
            alias_email: updated_alias.alias_email,
            action: action
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "Alias #{action} successfully.")
        |> redirect(to: ~p"/pripyat/aliases")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to toggle alias.")
        |> redirect(to: ~p"/pripyat/aliases")
    end
  end

  def delete(conn, %{"id" => id}) do
    alias_record = Repo.get!(Email.Alias, id)

    case Email.delete_alias(alias_record) do
      {:ok, _deleted_alias} ->
        # Log the deletion
        Elektrine.AuditLog.log(
          conn.assigns.current_user.id,
          "delete_alias",
          "alias",
          details: %{
            alias_id: alias_record.id,
            alias_email: alias_record.alias_email,
            target_email: alias_record.target_email
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "Alias deleted successfully.")
        |> redirect(to: ~p"/pripyat/aliases")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to delete alias.")
        |> redirect(to: ~p"/pripyat/aliases")
    end
  end

  def forwarded_messages(conn, params) do
    search_query = Map.get(params, "search", "")
    page = SafeConvert.parse_page(params)
    per_page = 50

    # Base query for counting (without select)
    base_query =
      from(fm in Email.ForwardedMessage, left_join: a in Email.Alias, on: fm.alias_id == a.id)

    base_query =
      if search_query != "" do
        search_pattern = "%#{search_query}%"

        from([fm, a] in base_query,
          where:
            ilike(fm.from_address, ^search_pattern) or
              ilike(fm.subject, ^search_pattern) or
              ilike(fm.original_recipient, ^search_pattern) or
              ilike(fm.final_recipient, ^search_pattern) or
              ilike(a.alias_email, ^search_pattern)
        )
      else
        base_query
      end

    total_count = Repo.aggregate(base_query, :count)

    # Query with select for fetching data
    query =
      from([fm, a] in base_query,
        select: %{
          id: fm.id,
          message_id: fm.message_id,
          from_address: fm.from_address,
          subject: fm.subject,
          original_recipient: fm.original_recipient,
          final_recipient: fm.final_recipient,
          forwarding_chain: fm.forwarding_chain,
          total_hops: fm.total_hops,
          alias_email: a.alias_email,
          inserted_at: fm.inserted_at
        }
      )

    forwarded_messages =
      query
      |> order_by([fm], desc: fm.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :forwarded_messages,
      forwarded_messages: forwarded_messages,
      search_query: search_query,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  # Private helper functions

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

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end
end
