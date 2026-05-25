defmodule Maid.ProvidersTest do
  use ExUnit.Case, async: true

  alias Maid.Providers.{Brave, GitHub, HackerNews, Wikipedia}
  alias Maid.Result

  test "Brave provider maps web results" do
    request_fun = fn url, headers, _opts ->
      assert url =~ "https://api.search.brave.com/res/v1/web/search?"
      assert url =~ "q=elektrine"
      assert url =~ "count=20"
      assert {"X-Subscription-Token", "brave-token"} in headers

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             web: %{
               results: [
                 %{title: "Elektrine", url: "https://elektrine.com", description: "Platform"}
               ]
             }
           })
       }}
    end

    assert {:ok, [%Result{} = result]} =
             Brave.search("elektrine",
               api_key: "brave-token",
               limit: 50,
               request_fun: request_fun
             )

    assert result.title == "Elektrine"
    assert result.url == "https://elektrine.com"
    assert result.source == "Brave"
    assert result.metadata.provider == :brave
  end

  test "Brave provider requires an API key" do
    assert Brave.search("elektrine", request_fun: fn _, _, _ -> flunk("should not request") end) ==
             {:error, :missing_api_key}
  end

  test "Brave provider maps image results" do
    request_fun = fn url, headers, _opts ->
      assert url =~ "https://api.search.brave.com/res/v1/images/search?"
      assert url =~ "q=elektrine"
      assert url =~ "count=200"
      assert url =~ "country=us"
      assert url =~ "search_lang=en"
      assert url =~ "spellcheck=1"
      assert {"X-Subscription-Token", "brave-token"} in headers

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             results: [
               %{
                 title: "Elektrine screenshot",
                 url: "https://elektrine.com/screenshot",
                 thumbnail: %{src: "https://images.example/elektrine.jpg"}
               }
             ]
           })
       }}
    end

    assert {:ok, [%Result{} = result]} =
             Brave.search("elektrine",
               api_key: "brave-token",
               kind: :images,
               limit: 250,
               request_fun: request_fun
             )

    assert result.title == "Elektrine screenshot"
    assert result.url == "https://elektrine.com/screenshot"
    assert result.metadata.kind == :images
    assert result.metadata.image_url == "https://images.example/elektrine.jpg"
  end

  test "Wikipedia provider maps search results" do
    request_fun = fn url, headers, _opts ->
      assert url =~ "https://en.wikipedia.org/w/api.php?"
      assert url =~ "srsearch=elixir"
      assert {"Accept", "application/json"} in headers

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             query: %{
               search: [
                 %{
                   title: "Elixir (programming language)",
                   snippet: "A &lt;b&gt;functional&lt;/b&gt; language",
                   size: 42,
                   pageid: 123
                 }
               ]
             }
           })
       }}
    end

    assert {:ok, [%Result{} = result]} = Wikipedia.search("elixir", request_fun: request_fun)
    assert result.url == "https://en.wikipedia.org/wiki/Elixir_(programming_language)"
    assert result.snippet == "A functional language"
    assert result.metadata.page_id == 123
  end

  test "Hacker News provider maps Algolia hits" do
    request_fun = fn url, _headers, _opts ->
      assert url =~ "https://hn.algolia.com/api/v1/search?"
      assert url =~ "tags=story"

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             hits: [
               %{
                 objectID: "42",
                 title: "Show HN: Elektrine",
                 url: "https://elektrine.com",
                 points: 100,
                 num_comments: 20,
                 created_at: "2026-05-24T12:00:00Z"
               }
             ]
           })
       }}
    end

    assert {:ok, [%Result{} = result]} = HackerNews.search("elektrine", request_fun: request_fun)
    assert result.title == "Show HN: Elektrine"
    assert result.score == 102.0
    assert result.metadata.object_id == "42"
  end

  test "GitHub provider maps repository results" do
    request_fun = fn url, headers, _opts ->
      assert url =~ "https://api.github.com/search/repositories?"
      assert url =~ "q=phoenix"
      assert {"Authorization", "Bearer gh-token"} in headers

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             items: [
               %{
                 full_name: "phoenixframework/phoenix",
                 html_url: "https://github.com/phoenixframework/phoenix",
                 description: "Phoenix Framework",
                 stargazers_count: 25_000,
                 language: "Elixir",
                 pushed_at: "2026-05-24T12:00:00Z"
               }
             ]
           })
       }}
    end

    assert {:ok, [%Result{} = result]} =
             GitHub.search("phoenix", token: "gh-token", request_fun: request_fun)

    assert result.title == "phoenixframework/phoenix"
    assert result.score == 25_000
    assert result.metadata.language == "Elixir"
  end
end
