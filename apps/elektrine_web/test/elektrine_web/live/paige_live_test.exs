defmodule ElektrineWeb.MaidLiveTest do
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

  defmodule BrokenProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts), do: {:error, :offline}
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
  end

  test "runs configured Paige providers from query params", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    assert html =~ "Paige meta-search"
    assert html =~ "https://paige.example/search"
    assert html =~ "Private meta-search &amp; discovery for Elektrine"
    refute html =~ "&lt;b&gt;Private&lt;/b&gt;"
  end

  test "drops unsafe Paige result URLs and strips unsafe thumbnails", %{conn: conn} do
    Application.put_env(:paige, :providers, [UnsafeSearchProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=unsafe")

    refute html =~ "Dropped result"
    refute html =~ "javascript:"
    assert html =~ "Safe result with unsafe image"
    assert html =~ ~s|href="https://paige.example/safe"|
    refute html =~ "evil.test"
  end

  test "shows a degraded notice when some web providers fail", %{conn: conn} do
    Application.put_env(:paige, :providers, [SearchProvider, BrokenProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    assert html =~ "Paige meta-search"
    assert html =~ "Some web sources were unavailable"
  end

  test "blocking a domain removes its results", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    assert html =~ "Paige meta-search"
    assert html =~ "Adjust ranking for paige.example"

    html =
      render_click(view, "set_domain_rule", %{"domain" => "paige.example", "action" => "block"})

    refute html =~ "Paige meta-search"
    assert Elektrine.Search.DomainRules.rules_map(user.id) == %{"paige.example" => :block}
  end

  test "pinning a domain moves its results to the top", %{conn: conn} do
    Application.put_env(:paige, :providers, [SearchProvider, OtherDomainProvider])
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    assert index_of(html, "Other domain result") < index_of(html, "Paige meta-search")

    html =
      render_click(view, "set_domain_rule", %{"domain" => "paige.example", "action" => "pin"})

    assert index_of(html, "Paige meta-search") < index_of(html, "Other domain result")
  end

  test "removing a domain rule restores results", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, _rule} = Elektrine.Search.DomainRules.set_rule(user, "paige.example", "block")

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige?q=meta")

    refute html =~ "Paige meta-search"

    html = render_click(view, "remove_domain_rule", %{"domain" => "paige.example"})

    assert html =~ "Paige meta-search"
    assert Elektrine.Search.DomainRules.rules_map(user.id) == %{}
  end

  defp index_of(html, text) do
    {index, _length} = :binary.match(html, text)
    index
  end

  test "search input does not send keyup search events", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/paige")

    refute html =~ ~s(phx-keyup="suggest")
    refute html =~ ~s(phx-debounce="350")
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
