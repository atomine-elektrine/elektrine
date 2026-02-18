defmodule ElektrineWeb.Admin.MailboxesController do
  @moduledoc """
  Controller for admin mailbox management including listing and deleting mailboxes.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Email, Repo}
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
end
