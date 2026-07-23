defmodule ElektrineWeb.PaigeLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  defmodule SearchProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %{
           title: "Paige meta-search",
           url: "https://paige.example/search",
           snippet: "<b>Private</b> meta-search &amp; discovery for Elektrine",
           score: 5
         }
       ]}
    end
  end

  defmodule UnsafeSearchProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %{
           title: "Dropped result",
           url: "javascript:alert(1)",
           snippet: "This should not render",
           score: 10,
           metadata: %{image_url: "https://cdn.example/dropped.jpg"}
         },
         %{
           title: "Safe result with unsafe image",
           url: "https://paige.example/safe",
           snippet: "This should render without the thumbnail",
           score: 9,
           metadata: %{image_url: "https://example.com\r\nLocation:https://evil.test"}
         }
       ]}
    end
  end

  defmodule OtherDomainProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %{
           title: "Other domain result",
           url: "https://other.example/page",
           snippet: "A result from another domain",
           score: 999
         }
       ]}
    end
  end

  defmodule CorroboratingProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %{
           title: "Corroborating result",
           url: "https://paige.example/search",
           snippet: "The same URL from another source",
           source: "Wikipedia",
           score: 4
         }
       ]}
    end
  end

  defmodule BrokenProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts), do: {:error, :offline}
  end

  defmodule ControlledProvider do
    @behaviour Paige.Provider

    @impl true
    def search(query, opts) do
      notify = Keyword.fetch!(opts, :notify)
      send(notify, {:provider_started, query, self()})

      if query == Keyword.get(opts, :block_query) do
        receive do
          :release -> :ok
        after
          5_000 -> exit(:provider_test_timeout)
        end
      end

      {:ok,
       [
         %{
           title: "Result for #{query}",
           url: "https://controlled.example/#{URI.encode(query)}",
           snippet: "Controlled search result",
           score: 10
         }
       ]}
    end
  end

  defmodule OptionsProvider do
    @behaviour Paige.Provider

    @impl true
    def search(query, opts) do
      send(Keyword.fetch!(opts, :notify), {:provider_options, query, opts})

      {:ok,
       [
         %{
           title: "Filtered result",
           url: "https://filters.example/result",
           score: 10
         }
       ]}
    end
  end

  defmodule PaginatedProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, opts) do
      page = Keyword.fetch!(opts, :page)
      limit = Keyword.fetch!(opts, :limit)

      {:ok,
       for index <- 1..limit do
         %{
           title: "Page #{page} result #{index}",
           url: "https://pages.example/#{page}/#{index}",
           score: limit - index
         }
       end}
    end
  end

  setup do
    previous_providers = Application.get_env(:paige, :providers, [])

    Application.put_env(:paige, :providers, [SearchProvider])

    on_exit(fn -> Application.put_env(:paige, :providers, previous_providers) end)

    :ok
  end

  test "renders Paige from the main navigation", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige")

    assert html =~ "Paige"
    assert html =~ "Search"
    assert html =~ "Paige..."
    assert html =~ ~s(href="/paige")
    assert html =~ ~s(phx-hook="PaigeSearch")
    assert html =~ ~s(id="global-search-input")
  end

  test "runs configured Paige providers from query params", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    html = render_async(view, 1_000)

    assert html =~ "Paige meta-search"
    assert html =~ "https://paige.example/search"
    assert html =~ "Private meta-search &amp; discovery for Elektrine"
    assert html =~ "via SearchProvider"
    refute html =~ "&lt;b&gt;Private&lt;/b&gt;"
  end

  test "shows compact provenance when sources agree on a URL", %{conn: conn} do
    Application.put_env(:paige, :providers, [SearchProvider, CorroboratingProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta&lens=web")

    html = render_async(view, 1_000)

    assert html =~ "via SearchProvider + Wikipedia"
    assert length(:binary.matches(html, ~s(href="https://paige.example/search"))) == 1
  end

  test "drops unsafe Paige result URLs and strips unsafe thumbnails", %{conn: conn} do
    Application.put_env(:paige, :providers, [UnsafeSearchProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=unsafe")

    html = render_async(view, 1_000)

    refute html =~ "Dropped result"
    refute html =~ "javascript:"
    assert html =~ "Safe result with unsafe image"
    assert html =~ ~s|href="https://paige.example/safe"|
    refute html =~ "evil.test"
  end

  test "shows a degraded notice when some web providers fail", %{conn: conn} do
    Application.put_env(:paige, :providers, [SearchProvider, BrokenProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    html = render_async(view, 1_000)

    assert html =~ "Paige meta-search"
    assert html =~ "Some web sources were unavailable"
  end

  test "renders loading immediately and completes provider work asynchronously", %{conn: conn} do
    query = "blocked-#{System.unique_integer([:positive])}"

    Application.put_env(:paige, :providers, [
      {ControlledProvider, [notify: self(), block_query: query]}
    ])

    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=#{query}&lens=web")

    assert html =~ "skeleton"
    assert_receive {:provider_started, ^query, provider_pid}

    send(provider_pid, :release)
    html = render_async(view, 1_000)

    assert html =~ "Result for #{query}"
    refute html =~ "skeleton"
  end

  test "a newer query cannot be overwritten by a stale async result", %{conn: conn} do
    first_query = "blocked-#{System.unique_integer([:positive])}"
    second_query = "newer-#{System.unique_integer([:positive])}"

    Application.put_env(:paige, :providers, [
      {ControlledProvider, [notify: self(), block_query: first_query]}
    ])

    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=#{first_query}&lens=web")

    assert_receive {:provider_started, ^first_query, _provider_pid}

    render_patch(view, ~p"/paige?q=#{second_query}&lens=web")
    html = render_async(view, 1_000)

    assert html =~ "Result for #{second_query}"
    refute html =~ "Result for #{first_query}"
  end

  test "normalizes URL filters and forwards the provider contract", %{conn: conn} do
    Application.put_env(:paige, :providers, [{OptionsProvider, [notify: self()]}])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=filtered&lens=web&page=99&freshness=week&safesearch=off")

    html = render_async(view, 1_000)

    assert_receive {:provider_options, "filtered", opts}
    assert opts[:page] == 10
    assert opts[:freshness] == "pw"
    assert opts[:safesearch] == "off"
    assert html =~ "Page 10"
    assert has_element?(view, "a[rel=prev]", "Previous")
    assert has_element?(view, "option[value=week][selected]")
    assert has_element?(view, "option[value=off][selected]")
  end

  test "all searches every external vertical and deduplicates their URLs", %{conn: conn} do
    Application.put_env(:paige, :providers, [{OptionsProvider, [notify: self()]}])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=blended")

    html = render_async(view, 1_000)

    kinds =
      for _index <- 1..4 do
        assert_receive {:provider_options, "blended", opts}
        opts[:kind]
      end

    assert MapSet.new(kinds) == MapSet.new([:web, :images, :videos, :news])
    assert length(:binary.matches(html, ~s(href="https://filters.example/result"))) == 1
  end

  test "renders URL-backed next and previous pagination", %{conn: conn} do
    Application.put_env(:paige, :providers, [{PaginatedProvider, [paginated: true]}])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=pages&lens=web&freshness=month&safesearch=strict")

    render_async(view, 1_000)
    assert has_element?(view, "a[rel=next]", "Next")

    view |> element("a[rel=next]") |> render_click()
    html = render_async(view, 1_000)

    assert html =~ "Page 2"
    assert html =~ "Page 2 result 1"
    assert has_element?(view, "a[rel=prev]", "Previous")
    assert has_element?(view, "option[value=month][selected]")
    assert has_element?(view, "option[value=strict][selected]")
  end

  test "distinguishes unconfigured and unavailable web search", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    Application.put_env(:paige, :providers, [])

    {:ok, unconfigured_view, _html} =
      conn |> log_in_user(user) |> live(~p"/paige?q=none&lens=web")

    unconfigured_html = render_async(unconfigured_view, 1_000)

    assert unconfigured_html =~ "Web search is not configured"
    assert unconfigured_html =~ "Check again"

    Application.put_env(:paige, :providers, [BrokenProvider])
    render_patch(unconfigured_view, ~p"/paige?q=offline&lens=web")
    error_html = render_async(unconfigured_view, 1_000)

    assert error_html =~ "Search is temporarily unavailable"
    assert error_html =~ "Retry search"
  end

  test "rejects oversized direct queries before calling providers", %{conn: conn} do
    Application.put_env(:paige, :providers, [{OptionsProvider, [notify: self()]}])
    user = AccountsFixtures.user_fixture()
    query = String.duplicate("a", 401)

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live("/paige?" <> URI.encode_query(%{"q" => query, "lens" => "web"}))

    assert html =~ "Search query is too long"
    assert html =~ "400 characters or fewer"
    refute_receive {:provider_options, _, _}
  end

  test "blocking a domain removes its results", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    html = render_async(view, 1_000)

    assert html =~ "Paige meta-search"
    assert html =~ "Adjust ranking for paige.example"

    render_click(view, "set_domain_rule", %{"domain" => "paige.example", "action" => "block"})
    html = render_async(view, 1_000)

    refute html =~ "Paige meta-search"
    assert Elektrine.Search.DomainRules.rules_map(user.id) == %{"paige.example" => :block}
  end

  test "pinning a domain moves its results to the top", %{conn: conn} do
    Application.put_env(:paige, :providers, [SearchProvider, OtherDomainProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    html = render_async(view, 1_000)

    assert index_of(html, "Other domain result") < index_of(html, "Paige meta-search")

    render_click(view, "set_domain_rule", %{"domain" => "paige.example", "action" => "pin"})
    html = render_async(view, 1_000)

    assert index_of(html, "Paige meta-search") < index_of(html, "Other domain result")
  end

  test "removing a domain rule restores results", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, _rule} = Elektrine.Search.DomainRules.set_rule(user, "paige.example", "block")

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    html = render_async(view, 1_000)

    refute html =~ "Paige meta-search"

    render_click(view, "remove_domain_rule", %{"domain" => "paige.example"})
    html = render_async(view, 1_000)

    assert html =~ "Paige meta-search"
    assert Elektrine.Search.DomainRules.rules_map(user.id) == %{}
  end

  defp index_of(html, text) do
    {index, _length} = :binary.match(html, text)
    index
  end

  test "search input is an accessible debounced combobox", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige")

    assert html =~ ~s(role="search")
    assert html =~ ~s(role="combobox")
    assert html =~ ~s(aria-controls="paige-search-suggestions")
    assert html =~ ~s(phx-change="suggest")
    assert html =~ ~s(phx-debounce="300")
    assert html =~ ~s(type="search")
    assert html =~ ~s(maxlength="400")
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
