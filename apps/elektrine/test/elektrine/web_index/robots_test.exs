defmodule Elektrine.WebIndex.RobotsTest do
  use ExUnit.Case, async: true

  alias Elektrine.WebIndex.Robots

  test "prefers PaigeBot rules and applies the longest matching directive" do
    policy =
      Robots.parse("""
      User-agent: *
      Disallow: /

      User-agent: PaigeBot
      Disallow: /private/
      Allow: /private/public/
      Crawl-delay: 1.5
      Sitemap: https://example.com/sitemap.xml
      """)

    refute Robots.allowed?(policy, "https://example.com/private/report")
    assert Robots.allowed?(policy, "https://example.com/private/public/index.html")
    assert Robots.allowed?(policy, "https://example.com/about")
    assert Robots.crawl_delay_ms(policy) == 1_500
    assert Robots.sitemaps(policy) == ["https://example.com/sitemap.xml"]
  end

  test "supports wildcards and end anchors" do
    policy = Robots.parse("User-agent: *\nDisallow: /*?secret=*\nAllow: /public$")

    refute Robots.allowed?(policy, "https://example.com/page?secret=yes")
    assert Robots.allowed?(policy, "https://example.com/public")
    assert Robots.allowed?(policy, "https://example.com/public/more")
  end
end
