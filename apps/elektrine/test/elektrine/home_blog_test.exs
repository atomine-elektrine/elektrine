defmodule Elektrine.HomeBlogTest do
  use ExUnit.Case, async: false

  alias Elektrine.AppCache
  alias Elektrine.HomeBlog

  setup do
    original = Application.get_env(:elektrine, :home_blog_feed_url)
    AppCache.cache_home_blog_posts([])

    on_exit(fn ->
      Application.put_env(:elektrine, :home_blog_feed_url, original)
    end)

    :ok
  end

  test "returns no posts when the feed is not configured" do
    Application.put_env(:elektrine, :home_blog_feed_url, nil)

    assert HomeBlog.cached_posts() == []
    assert HomeBlog.latest_posts() == []
  end

  test "serves cached posts without fetching" do
    Application.put_env(:elektrine, :home_blog_feed_url, "https://example.com/atom.xml")

    posts = [
      %{
        title: "Hello world",
        url: "https://example.com/blog/hello/",
        published_at: ~U[2026-07-20 00:00:00Z]
      }
    ]

    AppCache.cache_home_blog_posts(posts)

    assert HomeBlog.cached_posts() == posts
    assert HomeBlog.latest_posts() == posts
  end

  test "a cached empty result is served without refetching" do
    Application.put_env(:elektrine, :home_blog_feed_url, "https://example.com/atom.xml")

    AppCache.cache_home_blog_posts([])

    assert HomeBlog.cached_posts() == []
    assert HomeBlog.latest_posts() == []
  end
end
