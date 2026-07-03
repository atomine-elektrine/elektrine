defmodule ElektrineSocialWeb.Live.GlobalFeedPage do
  @moduledoc """
  Serves the first page of a global (non-personalized) feed from a short-lived
  cache, falling back to (and caching) the real feed query on a miss.

  Bypassed in the test environment so the global cache key cannot leak
  content across test cases.
  """

  def fetch(scope, loader) when is_function(loader, 0) do
    if Elektrine.RuntimeEnv.environment() == :test do
      loader.()
    else
      case Elektrine.AppCache.get_global_feed(scope) do
        nil ->
          posts = loader.()
          Elektrine.AppCache.cache_global_feed(scope, posts)
          posts

        posts ->
          posts
      end
    end
  end
end
