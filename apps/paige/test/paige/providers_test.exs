defmodule Paige.ProvidersTest do
  use ExUnit.Case, async: true

  alias Paige.Providers.{Brave, GitHub, HackerNews, Wikipedia}
  alias Paige.Result

  test "Brave provider maps web results" do
    request_fun = fn url, headers, _opts ->
      assert URI.parse(url).path == "/res/v1/web/search"

      assert query_params(url) == %{
               "count" => "20",
               "country" => "us",
               "freshness" => "pw",
               "offset" => "2",
               "q" => "elektrine",
               "safesearch" => "off",
               "search_lang" => "en",
               "spellcheck" => "1"
             }

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
               page: 3,
               freshness: "week",
               safesearch: :off,
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
      assert URI.parse(url).path == "/res/v1/images/search"

      assert query_params(url) == %{
               "count" => "200",
               "country" => "us",
               "q" => "elektrine",
               "safesearch" => "strict",
               "search_lang" => "en",
               "spellcheck" => "1"
             }

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
               page: 4,
               freshness: "pd",
               safesearch: "moderate",
               request_fun: request_fun
             )

    assert result.title == "Elektrine screenshot"
    assert result.url == "https://elektrine.com/screenshot"
    assert result.metadata.kind == :images
    assert result.metadata.image_url == "https://images.example/elektrine.jpg"
  end

  test "Brave forwards pagination and filters for video and news searches" do
    Enum.each([{:videos, "/res/v1/videos/search"}, {:news, "/res/v1/news/search"}], fn
      {kind, expected_path} ->
        request_fun = fn url, _headers, _opts ->
          assert URI.parse(url).path == expected_path

          assert query_params(url) == %{
                   "count" => "17",
                   "country" => "ca",
                   "freshness" => "2026-01-01to2026-01-31",
                   "offset" => "9",
                   "q" => "phoenix liveview",
                   "safesearch" => "strict",
                   "search_lang" => "fr",
                   "spellcheck" => "0"
                 }

          {:ok, %{status: 200, body: Jason.encode!(%{results: []})}}
        end

        assert {:ok, []} =
                 Brave.search("phoenix liveview",
                   api_key: "brave-token",
                   kind: kind,
                   limit: 17,
                   page: 99,
                   freshness: "2026-01-01to2026-01-31",
                   safesearch: "strict",
                   country: "ca",
                   search_lang: "fr",
                   spellcheck: 0,
                   request_fun: request_fun
                 )
    end)
  end

  test "Wikipedia provider maps search results" do
    request_fun = fn url, headers, _opts ->
      assert URI.parse(url).path == "/w/api.php"

      assert query_params(url) == %{
               "action" => "query",
               "format" => "json",
               "list" => "search",
               "srlimit" => "5",
               "sroffset" => "10",
               "srsearch" => "elixir",
               "utf8" => "1"
             }

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

    assert {:ok, [%Result{} = result]} =
             Wikipedia.search("elixir", page: 3, request_fun: request_fun)

    assert result.url == "https://en.wikipedia.org/wiki/Elixir_(programming_language)"
    assert result.snippet == "A functional language"
    assert result.metadata.page_id == 123
  end

  test "Hacker News provider maps Algolia hits" do
    request_fun = fn url, _headers, _opts ->
      assert URI.parse(url).path == "/api/v1/search"

      assert query_params(url) == %{
               "hitsPerPage" => "10",
               "page" => "3",
               "query" => "elektrine",
               "tags" => "story"
             }

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

    assert {:ok, [%Result{} = result]} =
             HackerNews.search("elektrine", page: "4", request_fun: request_fun)

    assert result.title == "Show HN: Elektrine"
    assert result.score == 102.0
    assert result.metadata.object_id == "42"
  end

  test "GitHub provider maps repository results" do
    request_fun = fn url, headers, _opts ->
      assert URI.parse(url).path == "/search/repositories"

      assert query_params(url) == %{
               "order" => "desc",
               "page" => "3",
               "per_page" => "10",
               "q" => "phoenix",
               "sort" => "stars"
             }

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
             GitHub.search("phoenix", token: "gh-token", page: 3, request_fun: request_fun)

    assert result.title == "phoenixframework/phoenix"
    assert result.score == 25_000
    assert result.metadata.language == "Elixir"
  end

  test "providers reject unexpected schemas but accept valid empty result sets" do
    assert Brave.search("query", api_key: "token", request_fun: json_response(%{})) ==
             {:error, :invalid_response}

    assert Brave.search("query",
             api_key: "token",
             request_fun: json_response(%{"web" => %{"results" => []}})
           ) == {:ok, []}

    assert Wikipedia.search("query", request_fun: json_response(%{})) ==
             {:error, :invalid_response}

    assert Wikipedia.search("query",
             request_fun: json_response(%{"query" => %{"search" => []}})
           ) == {:ok, []}

    assert HackerNews.search("query", request_fun: json_response(%{})) ==
             {:error, :invalid_response}

    assert HackerNews.search("query", request_fun: json_response(%{"hits" => []})) ==
             {:ok, []}

    assert GitHub.search("query", request_fun: json_response(%{})) ==
             {:error, :invalid_response}

    assert GitHub.search("query", request_fun: json_response(%{"items" => []})) == {:ok, []}
  end

  test "providers isolate malformed entries inside an otherwise valid payload" do
    brave_payload = %{
      "web" => %{
        "results" => [
          %{"title" => %{"not" => "text"}, "url" => "https://bad.example"},
          %{"title" => "Valid Brave", "url" => "https://brave.example"}
        ]
      }
    }

    assert {:ok, [%Result{title: "Valid Brave"}]} =
             Brave.search("query", api_key: "token", request_fun: json_response(brave_payload))

    wikipedia_payload = %{
      "query" => %{
        "search" => [
          %{"title" => 123, "size" => 99},
          %{
            "title" => "Valid Wikipedia",
            "size" => "not-a-number",
            "snippet" => %{"not" => "text"}
          }
        ]
      }
    }

    assert {:ok, [%Result{title: "Valid Wikipedia", score: 0}]} =
             Wikipedia.search("query", request_fun: json_response(wikipedia_payload))

    hacker_news_payload = %{
      "hits" => [
        %{"objectID" => %{}, "title" => "Bad identifier"},
        %{
          "objectID" => "42",
          "title" => "Valid HN",
          "url" => "https://hn.example",
          "points" => "many",
          "num_comments" => %{}
        }
      ]
    }

    assert {:ok, [%Result{title: "Valid HN"} = hn_result]} =
             HackerNews.search("query", request_fun: json_response(hacker_news_payload))

    assert hn_result.score == 0.0

    github_payload = %{
      "items" => [
        %{"full_name" => ["bad"], "html_url" => "https://github.example/bad"},
        %{
          "full_name" => "valid/repository",
          "html_url" => "https://github.example/valid",
          "stargazers_count" => "many"
        }
      ]
    }

    assert {:ok, [%Result{title: "valid/repository", score: 0}]} =
             GitHub.search("query", request_fun: json_response(github_payload))
  end

  defp json_response(payload) do
    fn _url, _headers, _opts ->
      {:ok, %{status: 200, body: Jason.encode!(payload)}}
    end
  end

  defp query_params(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end
end
