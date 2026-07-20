defmodule Elektrine.HomeBlog do
  @moduledoc """
  Latest entries from the operator's blog feed, shown on the public home page.

  The feed is fetched server-side and cached, so visitors' browsers never
  contact the blog host. Override the source with:

      config :elektrine, :home_blog_feed_url, "https://example.com/atom.xml"

  Set it to nil to hide the section entirely (the test env does this).
  """

  require Logger

  alias Elektrine.AppCache
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.RSS.Parser

  @max_entries 3
  @user_agent "Elektrine/1.0 (Home Page)"
  @default_feed_url "https://maxfield.lol/atom.xml"

  def feed_url, do: Application.get_env(:elektrine, :home_blog_feed_url, @default_feed_url)

  @doc """
  Returns cached posts without ever touching the network.
  Suitable for the static render of the home page.
  """
  def cached_posts do
    if feed_url(), do: AppCache.get_home_blog_posts() || [], else: []
  end

  @doc """
  Returns the latest posts, fetching and caching the feed when the cache is
  cold. Failures are cached briefly as an empty list so a broken feed does not
  get refetched on every visit.
  """
  def latest_posts do
    case feed_url() do
      nil ->
        []

      url ->
        case AppCache.get_home_blog_posts() do
          posts when is_list(posts) ->
            posts

          nil ->
            posts = fetch_posts(url)
            AppCache.cache_home_blog_posts(posts)
            posts
        end
    end
  end

  defp fetch_posts(url) do
    headers = [
      {"user-agent", @user_agent},
      {"accept", "application/atom+xml, application/rss+xml, application/xml, text/xml"}
    ]

    request = Finch.build(:get, url, headers)

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           SafeFetch.request(request, Elektrine.Finch, receive_timeout: 10_000),
         {:ok, %{entries: entries}} <- Parser.parse(body) do
      entries
      |> Enum.filter(&(present?(&1.title) and present?(&1.link)))
      |> Enum.take(@max_entries)
      |> Enum.map(&%{title: &1.title, url: &1.link, published_at: &1.published_at})
    else
      other ->
        Logger.warning("Home blog feed fetch failed: #{inspect(other)}")
        []
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
