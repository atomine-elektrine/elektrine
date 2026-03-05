defmodule ElektrineWeb.WebFingerController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.Domains

  @doc """
  WebFinger endpoint for user and community discovery.
  Responds to queries like:
  - /.well-known/webfinger?resource=acct:username@domain.com (users)
  - /.well-known/webfinger?resource=!community@domain.com (communities, Lemmy format)

  Supports both JSON (JRD) and XML (XRD) formats based on Accept header.
  """
  def webfinger(conn, %{"resource" => resource}) do
    case parse_resource(resource) do
      {:ok, :user, username, requested_domain} ->
        handle_user_lookup(conn, username, requested_domain)

      {:ok, :community, community_name, requested_domain} ->
        handle_community_lookup(conn, community_name, requested_domain)

      {:error, :invalid_resource} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid resource format"})
    end
  end

  def webfinger(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing resource parameter"})
  end

  @doc """
  host-meta endpoint for LRDD (Link-based Resource Descriptor Discovery).
  Returns XRD format pointing to the WebFinger endpoint.
  Required by some older ActivityPub implementations.
  """
  def host_meta(conn, _params) do
    base_url = ActivityPub.instance_url()

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Link rel="lrdd" type="application/xrd+xml" template="#{base_url}/.well-known/webfinger?resource={uri}" />
    </XRD>
    """

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> send_resp(200, xml)
  end

  defp parse_resource("acct:" <> acct) do
    # Format:
    # - acct:username@domain.com (users)
    # - acct:!community@domain.com (communities, Lemmy/PieFed style)
    case String.split(acct, "@") do
      [username_or_community, domain] ->
        requested_domain = normalize_domain(domain)

        if Domains.local_activitypub_domain?(requested_domain) do
          parse_local_acct_identifier(username_or_community, requested_domain)
        else
          {:error, :invalid_resource}
        end

      _ ->
        {:error, :invalid_resource}
    end
  end

  defp parse_resource(resource) do
    # Community format: !community@domain
    if String.starts_with?(resource, "!") do
      # Format: !community@domain.com
      community_acct = String.trim_leading(resource, "!")

      case String.split(community_acct, "@") do
        [community_name, domain] ->
          requested_domain = normalize_domain(domain)

          if Domains.local_activitypub_domain?(requested_domain) do
            {:ok, :community, community_name, requested_domain}
          else
            {:error, :invalid_resource}
          end

        _ ->
          {:error, :invalid_resource}
      end
    else
      {:error, :invalid_resource}
    end
  end

  defp parse_local_acct_identifier("!" <> community_name, requested_domain)
       when community_name != "" do
    {:ok, :community, community_name, requested_domain}
  end

  defp parse_local_acct_identifier(username, requested_domain)
       when is_binary(username) and username != "" do
    {:ok, :user, username, requested_domain}
  end

  defp parse_local_acct_identifier(_, _), do: {:error, :invalid_resource}

  defp handle_user_lookup(conn, username, requested_domain) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        # Check if user has federation enabled
        if user.activitypub_enabled do
          render_webfinger(conn, user, requested_domain)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  defp handle_community_lookup(conn, community_name, requested_domain) do
    case Elektrine.Messaging.get_conversation_by_name(community_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Community not found"})

      community ->
        if community.type == "community" && community.is_public do
          render_community_webfinger(conn, community, requested_domain)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "Community not found"})
        end
    end
  end

  defp render_webfinger(conn, user, requested_domain) do
    base_url = webfinger_base_url(requested_domain)
    actor_url = "#{base_url}/users/#{user.username}"
    profile_url = "#{base_url}/#{user.handle}"
    subject_domain = requested_domain || ActivityPub.instance_domain()
    subject = "acct:#{user.username}@#{subject_domain}"

    links = [
      %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: profile_url},
      %{rel: "self", type: "application/activity+json", href: actor_url},
      %{
        rel: "self",
        type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        href: actor_url
      }
    ]

    aliases = [actor_url, profile_url]

    if wants_xml?(conn) do
      render_xrd(conn, subject, aliases, links)
    else
      render_jrd(conn, subject, aliases, links)
    end
  end

  defp render_community_webfinger(conn, community, requested_domain) do
    base_url = webfinger_base_url(requested_domain)
    community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")
    actor_url = "#{base_url}/c/#{community_slug}"
    web_url = "#{base_url}/communities/#{community.name}"
    subject_domain = requested_domain || ActivityPub.instance_domain()
    subject = "acct:!#{community.name}@#{subject_domain}"

    links = [
      %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: web_url},
      %{rel: "self", type: "application/activity+json", href: actor_url},
      %{
        rel: "self",
        type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        href: actor_url
      }
    ]

    aliases = [actor_url, web_url]

    if wants_xml?(conn) do
      render_xrd(conn, subject, aliases, links)
    else
      render_jrd(conn, subject, aliases, links)
    end
  end

  # Check if client prefers XML format
  defp wants_xml?(conn) do
    accept = get_req_header(conn, "accept") |> List.first() || ""

    cond do
      String.contains?(accept, "application/xrd+xml") -> true
      String.contains?(accept, "application/xml") -> true
      String.contains?(accept, "text/xml") -> true
      true -> false
    end
  end

  # Render JSON Resource Descriptor (JRD) format
  defp render_jrd(conn, subject, aliases, links) do
    webfinger_data = %{
      subject: subject,
      aliases: aliases,
      links: links
    }

    conn
    |> put_resp_content_type("application/jrd+json")
    |> json(webfinger_data)
  end

  # Render XML Resource Descriptor (XRD) format
  defp render_xrd(conn, subject, aliases, links) do
    alias_elements =
      Enum.map_join(aliases, "\n    ", fn a -> "<Alias>#{xml_escape(a)}</Alias>" end)

    link_elements =
      Enum.map(links, fn link ->
        type_attr = if link[:type], do: " type=\"#{xml_escape(link.type)}\"", else: ""
        "<Link rel=\"#{xml_escape(link.rel)}\"#{type_attr} href=\"#{xml_escape(link.href)}\" />"
      end)
      |> Enum.map_join("\n    ", & &1)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Subject>#{xml_escape(subject)}</Subject>
      #{alias_elements}
      #{link_elements}
    </XRD>
    """

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> send_resp(200, xml)
  end

  defp xml_escape(nil), do: ""

  defp xml_escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("www.")
  end

  defp webfinger_base_url(requested_domain) do
    requested = normalize_domain(requested_domain || "")
    move_from_domain = Domains.activitypub_move_from_domain()
    canonical_domain = ActivityPub.instance_domain()

    cond do
      requested != "" and requested == move_from_domain ->
        ActivityPub.instance_url_for_domain(requested)

      requested != "" and requested == canonical_domain ->
        ActivityPub.instance_url()

      true ->
        ActivityPub.instance_url()
    end
  end
end
