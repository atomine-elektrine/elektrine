defmodule Elektrine.Bluesky.FinchClient do
  @moduledoc false

  alias Elektrine.HTTP.SafeFetch

  def request(method, url, headers, body, opts) do
    request = Finch.build(method, url, headers, body)

    SafeFetch.request(
      request,
      Elektrine.Finch,
      Keyword.put_new(opts, :allow_private_network, true)
    )
  end
end
