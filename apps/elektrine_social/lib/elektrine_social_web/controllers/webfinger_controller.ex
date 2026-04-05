defmodule ElektrineSocialWeb.WebFingerController do
  use ElektrineSocialWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.Domains
  alias Elektrine.Profiles

  @doc """
  WebFinger endpoint for user and community discovery.
  Responds to queries like:
  - /.well-known/webfinger?resource=acct:username@domain.com (users)
  - /.well-known/webfinger?resource=!community@domain.com (communities, Lemmy format)

  Supports both JSON (JRD) and XML (XRD) formats based on Accept header.
  """
  def webfinger(conn, %{"resource" => resource}) do
    case parse_resource(resource) do
      {:ok, :user, identifier, requested_domain} ->
        handle_user_lookup(conn, identifier, requested_domain)

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
    base_url = host_meta_base_url(conn)

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

        cond do
          Domains.local_activitypub_domain?(requested_domain) ->
            parse_local_acct_identifier(username_or_community, requested_domain)

          custom_profile_alias_domain?(requested_domain) ->
            parse_custom_profile_acct_identifier(username_or_community, requested_domain)

          true ->
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

  defp parse_custom_profile_acct_identifier(username, requested_domain)
       when is_binary(username) and username != "" do
    if String.starts_with?(username, "!") do
      {:error, :invalid_resource}
    else
      {:ok, :user, username, requested_domain}
    end
  end

  defp parse_custom_profile_acct_identifier(_, _), do: {:error, :invalid_resource}

  defp handle_user_lookup(conn, identifier, requested_domain) do
    requested_identifier = ActivityPub.actor_identifier(identifier)

    case Accounts.get_user_by_activitypub_identifier(requested_identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "User not found"})

      user ->
        # Check if user has federation enabled
        if user.activitypub_enabled and allowed_requested_user_domain?(user, requested_domain) do
          render_webfinger(conn, user, requested_identifier, requested_domain)
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "User not found"})
        end
    end
  end

  defp handle_community_lookup(conn, community_name, requested_domain) do
    case ActivityPub.get_community_by_identifier(community_name) do
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

  defp render_webfinger(conn, user, requested_identifier, requested_domain) do
    base_url = webfinger_base_url(requested_domain)
    canonical_actor_url = ActivityPub.actor_uri(user, ActivityPub.instance_url())
    actor_url = webfinger_actor_url(user, requested_identifier, requested_domain)
    profile_url = webfinger_profile_url(user, requested_domain)
    subject_domain = requested_domain || ActivityPub.instance_domain()
    subject = "acct:#{requested_identifier}@#{subject_domain}"

    links = [
      %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: profile_url},
      %{rel: "self", type: "application/activity+json", href: actor_url},
      %{
        rel: "self",
        type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        href: actor_url
      },
      subscribe_link(base_url)
    ]

    aliases =
      [canonical_actor_url, actor_url, profile_url]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if wants_xml?(conn) do
      render_xrd(conn, subject, aliases, links)
    else
      render_jrd(conn, subject, aliases, links)
    end
  end

  defp render_community_webfinger(conn, community, requested_domain) do
    base_url = webfinger_base_url(requested_domain)
    community_slug = ActivityPub.community_slug(community.name)
    actor_url = ActivityPub.community_actor_uri(community.name, base_url)
    web_url = ActivityPub.community_web_url(community.name, base_url)
    subject_domain = requested_domain || ActivityPub.instance_domain()
    canonical_subject = "acct:!#{community_slug}@#{subject_domain}"

    links = [
      %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: web_url},
      %{rel: "self", type: "application/activity+json", href: actor_url},
      %{
        rel: "self",
        type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        href: actor_url
      },
      subscribe_link(base_url)
    ]

    aliases = [actor_url, web_url]

    if wants_xml?(conn) do
      render_xrd(conn, canonical_subject, aliases, links)
    else
      render_jrd(conn, canonical_subject, aliases, links)
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
        href_attr = if link[:href], do: " href=\"#{xml_escape(link.href)}\"", else: ""

        template_attr =
          if link[:template], do: " template=\"#{xml_escape(link.template)}\"", else: ""

        "<Link rel=\"#{xml_escape(link.rel)}\"#{type_attr}#{href_attr}#{template_attr} />"
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

  defp custom_profile_alias_domain?(requested_domain) when is_binary(requested_domain) do
    match?(%{domain: _}, Profiles.get_verified_custom_domain(requested_domain))
  end

  defp custom_profile_alias_domain?(_), do: false

  defp allowed_requested_user_domain?(user, requested_domain) do
    Domains.local_activitypub_domain?(requested_domain) or
      match?(%{domain: _}, custom_profile_domain_for_user(user, requested_domain))
  end

  defp custom_profile_domain_for_user(%{id: user_id}, requested_domain)
       when is_integer(user_id) and is_binary(requested_domain) do
    case Profiles.get_verified_custom_domain(requested_domain) do
      %{user_id: ^user_id} = custom_domain -> custom_domain
      _ -> nil
    end
  end

  defp custom_profile_domain_for_user(_, _), do: nil

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

  defp webfinger_actor_url(user, requested_identifier, requested_domain) do
    requested_domain = normalize_domain(requested_domain || "")
    move_from_domain = Domains.activitypub_move_from_domain()

    if requested_domain != "" and requested_domain == move_from_domain do
      ActivityPub.actor_uri(
        requested_identifier,
        ActivityPub.instance_url_for_domain(requested_domain)
      )
    else
      ActivityPub.actor_uri(user, ActivityPub.instance_url())
    end
  end

  defp webfinger_profile_url(user, requested_domain) do
    case custom_profile_domain_for_user(user, requested_domain) do
      %{domain: domain} ->
        ActivityPub.instance_url_for_domain(domain)

      _ ->
        handle =
          if is_binary(user.handle) and user.handle != "", do: user.handle, else: user.username

        "#{webfinger_base_url(requested_domain)}/#{handle}"
    end
  end

  defp host_meta_base_url(conn) do
    requested_host = normalize_domain(conn.host || "")

    if requested_host != "" and
         (Domains.local_activitypub_domain?(requested_host) or
            custom_profile_alias_domain?(requested_host)) do
      ActivityPub.instance_url_for_domain(requested_host)
    else
      ActivityPub.instance_url()
    end
  end

  defp subscribe_link(base_url) do
    %{
      rel: "http://ostatus.org/schema/1.0/subscribe",
      template: "#{base_url}/authorize_interaction?uri={uri}"
    }
  end
end
