defmodule ElektrineWeb.SitemapController do
  use ElektrineWeb, :controller

  def index(conn, _params) do
    base_url = ElektrineWeb.Endpoint.url()

    # Static pages
    static_urls = [
      %{loc: "#{base_url}/", changefreq: "daily", priority: "1.0"},
      %{loc: "#{base_url}/about", changefreq: "monthly", priority: "0.8"},
      %{loc: "#{base_url}/terms", changefreq: "monthly", priority: "0.5"},
      %{loc: "#{base_url}/privacy", changefreq: "monthly", priority: "0.5"},
      %{loc: "#{base_url}/faq", changefreq: "weekly", priority: "0.7"},
      %{loc: "#{base_url}/contact", changefreq: "monthly", priority: "0.6"},
      %{loc: "#{base_url}/login", changefreq: "monthly", priority: "0.9"},
      %{loc: "#{base_url}/register", changefreq: "monthly", priority: "0.9"},
      %{loc: "#{base_url}/timeline", changefreq: "hourly", priority: "0.9"},
      %{loc: "#{base_url}/discussions", changefreq: "hourly", priority: "0.8"},
      %{loc: "#{base_url}/chat", changefreq: "always", priority: "0.7"},
      %{loc: "#{base_url}/lists", changefreq: "daily", priority: "0.7"}
    ]

    # Get public timeline posts (recent 100)
    timeline_urls =
      try do
        import Ecto.Query

        recent_posts =
          from(m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: c.id == m.conversation_id,
            where:
              c.type == "timeline" and
                m.post_type == "post" and
                m.visibility == "public" and
                is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: 100,
            select: %{id: m.id, updated_at: m.updated_at}
          )
          |> Elektrine.Repo.all()

        Enum.map(recent_posts, fn post ->
          %{
            loc: "#{base_url}/timeline/post/#{post.id}",
            lastmod: format_date(post.updated_at || post.inserted_at),
            changefreq: "weekly",
            priority: "0.6"
          }
        end)
      rescue
        _ -> []
      end

    # Get public community discussions
    discussion_urls =
      try do
        import Ecto.Query

        recent_discussions =
          from(m in Elektrine.Messaging.Message,
            join: c in Elektrine.Messaging.Conversation,
            on: c.id == m.conversation_id,
            where:
              c.type == "community" and
                m.post_type == "post" and
                is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: 100,
            preload: [:conversation],
            select: m
          )
          |> Elektrine.Repo.all()

        Enum.map(recent_discussions, fn post ->
          slug = Elektrine.Utils.Slug.discussion_url_slug(post.id, post.title)

          %{
            loc: "#{base_url}/discussions/#{post.conversation.name}/p/#{slug}",
            lastmod: format_date(post.updated_at || post.inserted_at),
            changefreq: "weekly",
            priority: "0.6"
          }
        end)
      rescue
        _ -> []
      end

    # Get public lists
    list_urls =
      try do
        import Ecto.Query

        public_lists =
          from(l in Elektrine.Social.List,
            where: l.visibility == "public",
            order_by: [desc: l.updated_at],
            limit: 50,
            select: %{id: l.id, updated_at: l.updated_at}
          )
          |> Elektrine.Repo.all()

        Enum.map(public_lists, fn list ->
          %{
            loc: "#{base_url}/lists/#{list.id}",
            lastmod: format_date(list.updated_at),
            changefreq: "daily",
            priority: "0.5"
          }
        end)
      rescue
        _ -> []
      end

    all_urls = static_urls ++ timeline_urls ++ discussion_urls ++ list_urls

    conn
    |> put_resp_content_type("application/xml")
    |> render(:index, urls: all_urls)
  end

  def robots(conn, _params) do
    base_url = ElektrineWeb.Endpoint.url()

    robots_txt = """
    User-agent: *
    Allow: /
    Allow: /timeline
    Allow: /discussions
    Allow: /lists
    Allow: /about
    Allow: /faq
    Allow: /privacy
    Allow: /terms
    Disallow: /email
    Disallow: /chat
    Disallow: /pripyat
    Disallow: /admin
    Disallow: /account
    Disallow: /settings

    Sitemap: #{base_url}/sitemap.xml
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, robots_txt)
  end

  defp format_date(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_date(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
