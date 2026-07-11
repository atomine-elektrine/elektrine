defmodule Elektrine.WebIndex.FetcherTest do
  use ExUnit.Case, async: true

  alias Elektrine.WebIndex.Fetcher

  test "follows relative redirects on the same host" do
    request_fun = fn
      "https://example.com/start", _headers, _opts ->
        {:ok, %{status: 302, body: "", headers: [{"location", "/final"}]}}

      "https://example.com/final", _headers, _opts ->
        {:ok, %{status: 200, body: "done", headers: []}}
    end

    assert {:ok, %{status: 200, body: "done", url: "https://example.com/final"}} =
             Fetcher.get("https://example.com/start", request_fun: request_fun)
  end

  test "rejects cross-host redirects" do
    request_fun = fn _url, _headers, _opts ->
      {:ok, %{status: 302, body: "", headers: [{"location", "https://other.example/"}]}}
    end

    assert {:error, :invalid_redirect} =
             Fetcher.get("https://example.com/start", request_fun: request_fun)
  end
end
