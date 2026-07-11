defmodule Paige.ScraperProvidersTest do
  use ExUnit.Case, async: true

  alias Paige.Providers.{DuckDuckGo, Wiby}
  alias Paige.Result

  test "Wiby scraper parses server-rendered results and pagination" do
    request_fun = fn url, headers, _opts ->
      assert URI.parse(url).path == "/"
      assert URI.decode_query(URI.parse(url).query) == %{"p" => "3", "q" => "elixir lang"}
      assert {"Accept", "text/html,application/xhtml+xml"} in headers

      html = """
      <html><body>
        <form method="get"><input name="q" value="elixir lang"></form>
        <blockquote>
          <a class="tlink" href="https://elixir-lang.org/">The &lt;Elixir&gt; language</a>
          <p class="url">https://elixir-lang.org/</p>
          <p>A dynamic, functional language.<br>Runs on the Erlang VM.</p>
        </blockquote>
        <blockquote><a class="more" href="/?q=elixir&p=4">Find more</a></blockquote>
      </body></html>
      """

      {:ok, %{status: 200, body: html}}
    end

    assert {:ok, [%Result{} = result]} =
             Wiby.search("elixir lang",
               endpoint: "https://wiby.test/",
               page: 3,
               request_fun: request_fun
             )

    assert result.title == "The <Elixir> language"
    assert result.url == "https://elixir-lang.org/"
    assert result.snippet == "A dynamic, functional language. Runs on the Erlang VM."
    assert result.source == "Wiby"
    assert result.metadata == %{provider: :wiby, kind: :web}
  end

  test "Wiby accepts a valid empty page and rejects unrelated HTML" do
    valid_empty = "<html><body><form><input name=\"q\"></form></body></html>"

    assert Wiby.search("missing", request_fun: html_response(valid_empty)) == {:ok, []}

    assert Wiby.search("missing", request_fun: html_response("<html>changed</html>")) ==
             {:error, :invalid_response}
  end

  test "DuckDuckGo scraper parses result redirects and forwards search controls" do
    request_fun = fn url, headers, _opts ->
      assert URI.parse(url).path == "/html/"

      assert URI.decode_query(URI.parse(url).query) == %{
               "df" => "w",
               "kl" => "ca-fr",
               "kp" => "1",
               "q" => "phoenix framework",
               "s" => "60"
             }

      assert {"Accept-Language", "en-US,en;q=0.8"} in headers

      html = """
      <html><body>
        <div class="result">
          <h2>
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fphoenixframework.org%2F">
              Phoenix &amp; LiveView
            </a>
          </h2>
          <a class="result__snippet">Productive web development.</a>
        </div>
        <div class="result"><span>Malformed result</span></div>
      </body></html>
      """

      {:ok, %{status: 200, body: html}}
    end

    assert {:ok, [%Result{} = result]} =
             DuckDuckGo.search("phoenix framework",
               endpoint: "https://duckduckgo.test/html/",
               page: 3,
               freshness: "pw",
               safesearch: "strict",
               country: "ca",
               search_lang: "fr",
               request_fun: request_fun
             )

    assert result.title == "Phoenix & LiveView"
    assert result.url == "https://phoenixframework.org/"
    assert result.snippet == "Productive web development."
    assert result.source == "DuckDuckGo"
  end

  test "DuckDuckGo reports bot challenges instead of caching them as empty results" do
    challenge =
      "<html><form id=\"challenge-form\">Unfortunately, bots use DuckDuckGo too.</form></html>"

    assert DuckDuckGo.search("query", request_fun: html_response(challenge)) ==
             {:error, :blocked}
  end

  test "DuckDuckGo recognizes a genuine empty result page" do
    assert DuckDuckGo.search("missing", request_fun: html_response("<html>No results.</html>")) ==
             {:ok, []}
  end

  defp html_response(html) do
    fn _url, _headers, _opts -> {:ok, %{status: 200, body: html}} end
  end
end
