defmodule ElektrineWeb.Plugs.SitePageTracking do
  @moduledoc """
  Records site-wide HTML page visits for browser routes.
  """

  import Plug.Conn

  alias Elektrine.Profiles
  alias ElektrineWeb.ClientIP

  @tracked_methods ["GET", "HEAD"]
  @session_timeout_seconds 30 * 60

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.method in @tracked_methods do
      {conn, visitor_id} = ensure_site_visitor_id(conn)
      {conn, session_id} = ensure_site_session_id(conn)

      conn
      |> assign(:site_page_visitor_id, visitor_id)
      |> assign(:site_page_session_id, session_id)
      |> register_before_send(&track_page_visit/1)
    else
      conn
    end
  end

  defp track_page_visit(conn) do
    if html_response?(conn) and conn.status < 400 do
      current_user = conn.assigns[:current_user]
      viewer_user_id = if is_map(current_user), do: current_user.id, else: nil

      _ =
        Profiles.track_site_page_visit(
          viewer_user_id: viewer_user_id,
          visitor_id: conn.assigns[:site_page_visitor_id],
          session_id: conn.assigns[:site_page_session_id],
          ip_address: ClientIP.client_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first(),
          referer: get_req_header(conn, "referer") |> List.first(),
          request_host: conn.host,
          request_path: conn.request_path,
          status: conn.status
        )

      conn
    else
      conn
    end
  end

  defp html_response?(conn) do
    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "text/html"))
  end

  defp ensure_site_visitor_id(conn) do
    case conn.private[:plug_session_fetch] do
      :done ->
        case get_session(conn, :site_page_visitor_id) do
          visitor_id when is_binary(visitor_id) and visitor_id != "" ->
            {conn, visitor_id}

          _ ->
            visitor_id = Ecto.UUID.generate()
            {put_session(conn, :site_page_visitor_id, visitor_id), visitor_id}
        end

      _ ->
        {conn, Ecto.UUID.generate()}
    end
  end

  defp ensure_site_session_id(conn) do
    case conn.private[:plug_session_fetch] do
      :done ->
        current_time = System.system_time(:second)
        last_seen_at = get_session(conn, :site_page_session_seen_at)
        session_id = get_session(conn, :site_page_session_id)

        if active_session?(session_id, last_seen_at, current_time) do
          {put_session(conn, :site_page_session_seen_at, current_time), session_id}
        else
          session_id = Ecto.UUID.generate()

          conn =
            conn
            |> put_session(:site_page_session_id, session_id)
            |> put_session(:site_page_session_seen_at, current_time)

          {conn, session_id}
        end

      _ ->
        {conn, Ecto.UUID.generate()}
    end
  end

  defp active_session?(session_id, last_seen_at, current_time) do
    is_binary(session_id) and session_id != "" and is_integer(last_seen_at) and
      current_time - last_seen_at <= @session_timeout_seconds
  end
end
