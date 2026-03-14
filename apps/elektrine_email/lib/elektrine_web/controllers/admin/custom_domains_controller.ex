defmodule ElektrineWeb.Admin.CustomDomainsController do
  @moduledoc """
  Read-only admin console for user-owned custom email domains.
  """

  use ElektrineEmailWeb, :controller

  alias Elektrine.Email

  @status_filters ~w(all verified pending attention)

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  def index(conn, params) do
    search_query = Map.get(params, "search", "") |> normalize_search()
    status_filter = Map.get(params, "status", "all") |> normalize_status_filter()
    page = SafeConvert.parse_page(params)
    per_page = 20

    {custom_domains, total_count} =
      Email.list_custom_domains_admin(search_query, status_filter, page, per_page)

    total_pages = ceil(total_count / per_page)
    page_range = pagination_range(page, total_pages)

    render(conn, :custom_domains,
      custom_domains: custom_domains,
      search_query: search_query,
      status_filter: status_filter,
      status_filters: @status_filters,
      overview: Email.custom_domain_admin_stats(),
      current_page: page,
      total_pages: total_pages,
      total_count: total_count,
      page_range: page_range
    )
  end

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

  defp normalize_search(search_query) when is_binary(search_query), do: String.trim(search_query)
  defp normalize_search(_), do: ""

  defp normalize_status_filter(status_filter) when status_filter in @status_filters,
    do: status_filter

  defp normalize_status_filter(_), do: "all"

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
