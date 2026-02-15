defmodule ElektrineWeb.AdminAuditLogsController do
  use ElektrineWeb, :controller

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, params) do
    page = SafeConvert.parse_page(params)
    per_page = 50

    {audit_logs, total_count} =
      Elektrine.AuditLog.list_audit_logs(
        page: page,
        per_page: per_page
      )

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :index,
      audit_logs: audit_logs,
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

  # Pagination helper (copied from admin controller)
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
