defmodule Elektrine.Bluesky.FinchClient do
  @moduledoc false

  def request(method, url, headers, body, opts) do
    method
    |> Finch.build(url, headers, body)
    |> Finch.request(Elektrine.Finch, opts)
  end
end
