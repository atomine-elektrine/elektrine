defmodule ElektrineWeb.DAV.ResponseHelpers do
  @moduledoc """
  Helper functions for generating WebDAV XML responses.

  Handles:
  - PROPFIND responses (multi-status)
  - PROPPATCH responses
  - Error responses
  - Collection listings
  """

  import Plug.Conn

  @dav_ns "DAV:"
  @caldav_ns "urn:ietf:params:xml:ns:caldav"
  @carddav_ns "urn:ietf:params:xml:ns:carddav"
  @cs_ns "http://calendarserver.org/ns/"

  @doc """
  Sends a multi-status response with proper headers.
  """
  def send_multistatus(conn, responses) when is_list(responses) do
    xml = build_multistatus_xml(responses)

    conn
    |> put_resp_content_type("application/xml; charset=utf-8")
    |> put_dav_headers()
    |> send_resp(207, xml)
  end

  @doc """
  Sends a single resource response.
  """
  def send_resource(conn, content, content_type, etag \\ nil) do
    conn =
      conn
      |> put_resp_content_type(content_type)
      |> put_dav_headers()

    conn =
      if etag do
        put_resp_header(conn, "etag", "\"#{etag}\"")
      else
        conn
      end

    send_resp(conn, 200, content)
  end

  @doc """
  Sends a created response (201).
  """
  def send_created(conn, etag \\ nil) do
    conn = conn |> put_dav_headers()

    conn =
      if etag do
        put_resp_header(conn, "etag", "\"#{etag}\"")
      else
        conn
      end

    send_resp(conn, 201, "")
  end

  @doc """
  Sends a no-content response (204).
  """
  def send_no_content(conn, etag \\ nil) do
    conn = conn |> put_dav_headers()

    conn =
      if etag do
        put_resp_header(conn, "etag", "\"#{etag}\"")
      else
        conn
      end

    send_resp(conn, 204, "")
  end

  @doc """
  Sends a precondition failed response (412).
  """
  def send_precondition_failed(conn) do
    conn
    |> put_dav_headers()
    |> send_resp(412, "Precondition Failed")
  end

  @doc """
  Sends a not found response (404).
  """
  def send_not_found(conn) do
    conn
    |> put_dav_headers()
    |> send_resp(404, "Not Found")
  end

  @doc """
  Sends a forbidden response (403).
  """
  def send_forbidden(conn) do
    conn
    |> put_dav_headers()
    |> send_resp(403, "Forbidden")
  end

  @doc """
  Adds DAV-specific headers to response.
  """
  def put_dav_headers(conn) do
    conn
    |> put_resp_header("dav", "1, 2, 3, calendar-access, addressbook")
    |> put_resp_header(
      "allow",
      "GET, PUT, DELETE, OPTIONS, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR"
    )
  end

  @doc """
  Builds a multi-status XML response from a list of response maps.

  Each response should have:
  - href: URL of the resource
  - propstat: list of {status, props} tuples
  """
  def build_multistatus_xml(responses) do
    responses_xml = Enum.map_join(responses, "\n", &build_response_xml/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="#{@dav_ns}" xmlns:C="#{@caldav_ns}" xmlns:A="#{@carddav_ns}" xmlns:CS="#{@cs_ns}">
    #{responses_xml}
    </D:multistatus>
    """
    |> String.trim()
  end

  defp build_response_xml(%{href: href, propstat: propstats}) do
    propstats_xml =
      Enum.map(propstats, fn {status, props} ->
        props_xml = build_props_xml(props)

        """
          <D:propstat>
            <D:prop>
        #{props_xml}
            </D:prop>
            <D:status>HTTP/1.1 #{status}</D:status>
          </D:propstat>
        """
      end)
      |> Enum.map_join("\n", & &1)

    """
      <D:response>
        <D:href>#{escape_xml(href)}</D:href>
    #{propstats_xml}
      </D:response>
    """
  end

  defp build_props_xml(props) when is_list(props) do
    Enum.map_join(props, "\n", &build_prop_xml/1)
  end

  defp build_prop_xml({:displayname, value}) do
    "      <D:displayname>#{escape_xml(value)}</D:displayname>"
  end

  defp build_prop_xml({:resourcetype, :collection}) do
    "      <D:resourcetype><D:collection/></D:resourcetype>"
  end

  defp build_prop_xml({:resourcetype, :calendar}) do
    "      <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>"
  end

  defp build_prop_xml({:resourcetype, :addressbook}) do
    "      <D:resourcetype><D:collection/><A:addressbook/></D:resourcetype>"
  end

  defp build_prop_xml({:resourcetype, nil}) do
    "      <D:resourcetype/>"
  end

  defp build_prop_xml({:getcontenttype, value}) do
    "      <D:getcontenttype>#{escape_xml(value)}</D:getcontenttype>"
  end

  defp build_prop_xml({:getcontentlength, value}) do
    "      <D:getcontentlength>#{value}</D:getcontentlength>"
  end

  defp build_prop_xml({:getetag, value}) do
    "      <D:getetag>\"#{escape_xml(value)}\"</D:getetag>"
  end

  defp build_prop_xml({:getlastmodified, %DateTime{} = dt}) do
    # RFC 2822 format
    formatted = Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
    "      <D:getlastmodified>#{formatted}</D:getlastmodified>"
  end

  defp build_prop_xml({:getlastmodified, %NaiveDateTime{} = ndt}) do
    dt = DateTime.from_naive!(ndt, "Etc/UTC")
    build_prop_xml({:getlastmodified, dt})
  end

  defp build_prop_xml({:creationdate, %DateTime{} = dt}) do
    "      <D:creationdate>#{DateTime.to_iso8601(dt)}</D:creationdate>"
  end

  defp build_prop_xml({:current_user_principal, href}) do
    """
          <D:current-user-principal>
            <D:href>#{escape_xml(href)}</D:href>
          </D:current-user-principal>
    """
  end

  defp build_prop_xml({:principal_url, href}) do
    """
          <D:principal-URL>
            <D:href>#{escape_xml(href)}</D:href>
          </D:principal-URL>
    """
  end

  defp build_prop_xml({:calendar_home_set, href}) do
    """
          <C:calendar-home-set>
            <D:href>#{escape_xml(href)}</D:href>
          </C:calendar-home-set>
    """
  end

  defp build_prop_xml({:addressbook_home_set, href}) do
    """
          <A:addressbook-home-set>
            <D:href>#{escape_xml(href)}</D:href>
          </A:addressbook-home-set>
    """
  end

  defp build_prop_xml({:supported_calendar_component_set, components}) do
    comps_xml =
      Enum.map(components, fn comp ->
        "        <C:comp name=\"#{comp}\"/>"
      end)
      |> Enum.map_join("\n", & &1)

    """
          <C:supported-calendar-component-set>
    #{comps_xml}
          </C:supported-calendar-component-set>
    """
  end

  defp build_prop_xml({:calendar_description, value}) do
    "      <C:calendar-description>#{escape_xml(value || "")}</C:calendar-description>"
  end

  defp build_prop_xml({:calendar_color, value}) do
    "      <A:calendar-color>#{escape_xml(value || "#3b82f6")}</A:calendar-color>"
  end

  defp build_prop_xml({:calendar_timezone, value}) do
    "      <C:calendar-timezone>#{escape_xml(value || "")}</C:calendar-timezone>"
  end

  defp build_prop_xml({:getctag, value}) do
    "      <CS:getctag>#{escape_xml(value)}</CS:getctag>"
  end

  defp build_prop_xml({:sync_token, value}) do
    "      <D:sync-token>#{escape_xml(value)}</D:sync-token>"
  end

  defp build_prop_xml({:calendar_data, value}) do
    "      <C:calendar-data>#{escape_xml(value)}</C:calendar-data>"
  end

  defp build_prop_xml({:address_data, value}) do
    "      <A:address-data>#{escape_xml(value)}</A:address-data>"
  end

  defp build_prop_xml({:supported_address_data, _}) do
    """
          <A:supported-address-data>
            <A:address-data-type content-type="text/vcard" version="3.0"/>
            <A:address-data-type content-type="text/vcard" version="4.0"/>
          </A:supported-address-data>
    """
  end

  defp build_prop_xml({:supported_report_set, reports}) do
    reports_xml =
      Enum.map(reports, fn report ->
        "        <D:supported-report><D:report><#{report}/></D:report></D:supported-report>"
      end)
      |> Enum.map_join("\n", & &1)

    """
          <D:supported-report-set>
    #{reports_xml}
          </D:supported-report-set>
    """
  end

  defp build_prop_xml({:owner, href}) do
    """
          <D:owner>
            <D:href>#{escape_xml(href)}</D:href>
          </D:owner>
    """
  end

  defp build_prop_xml({prop, value}) when is_atom(prop) do
    # Generic property
    "      <D:#{prop}>#{escape_xml(to_string(value))}</D:#{prop}>"
  end

  defp build_prop_xml(_), do: ""

  @doc """
  Escapes special XML characters in a string.
  """
  def escape_xml(nil), do: ""

  def escape_xml(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  def escape_xml(value), do: escape_xml(to_string(value))

  @doc """
  Parses a PROPFIND request body to extract requested properties.
  Returns {:ok, props} or {:ok, :allprop} or {:error, reason}
  """
  def parse_propfind_body(""), do: {:ok, :allprop}
  def parse_propfind_body(nil), do: {:ok, :allprop}

  def parse_propfind_body(body) do
    # Simple XML parsing - look for prop elements
    cond do
      String.contains?(body, "<allprop") ->
        {:ok, :allprop}

      String.contains?(body, "<propname") ->
        {:ok, :propname}

      String.contains?(body, "<prop") ->
        props = extract_prop_names(body)
        {:ok, props}

      true ->
        {:ok, :allprop}
    end
  end

  # Allowlist of valid WebDAV properties to prevent atom exhaustion DoS
  @valid_webdav_props %{
    "resourcetype" => :resourcetype,
    "getcontenttype" => :getcontenttype,
    "getcontentlength" => :getcontentlength,
    "getetag" => :getetag,
    "getlastmodified" => :getlastmodified,
    "creationdate" => :creationdate,
    "displayname" => :displayname,
    "supportedlock" => :supportedlock,
    "lockdiscovery" => :lockdiscovery,
    "owner" => :owner,
    "locktoken" => :locktoken,
    "href" => :href,
    "current-user-principal" => :"current-user-principal",
    "calendar-home-set" => :"calendar-home-set",
    "calendar-user-address-set" => :"calendar-user-address-set",
    "addressbook-home-set" => :"addressbook-home-set",
    "principal-URL" => :"principal-URL",
    "principal-collection-set" => :"principal-collection-set",
    "calendar-data" => :"calendar-data",
    "address-data" => :"address-data",
    "supported-calendar-component-set" => :"supported-calendar-component-set",
    "supported-address-data" => :"supported-address-data",
    "schedule-inbox-URL" => :"schedule-inbox-URL",
    "schedule-outbox-URL" => :"schedule-outbox-URL",
    "calendar-free-busy-set" => :"calendar-free-busy-set"
  }

  defp extract_prop_names(body) do
    # Extract property names from XML using regex
    # This is a simplified parser - production should use proper XML parsing
    regex = ~r/<(?:[A-Za-z]:)?([a-zA-Z_-]+)(?:\s|\/|>)/

    Regex.scan(regex, body)
    |> Enum.map(fn [_full, prop] ->
      # Only convert to atom if it's a known WebDAV property
      Map.get(@valid_webdav_props, prop)
    end)
    |> Enum.reject(&(is_nil(&1) || &1 in [:prop, :propfind, :multistatus]))
    |> Enum.uniq()
  end

  @doc """
  Parse Depth header from request.
  """
  def get_depth(conn) do
    case get_req_header(conn, "depth") do
      ["0"] -> 0
      ["1"] -> 1
      ["infinity"] -> :infinity
      _ -> :infinity
    end
  end
end
