defmodule ElektrineWeb.MaidLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  defmodule SearchProvider do
    @behaviour Maid.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %{
           title: "Maid meta-search",
           url: "https://maid.example/search",
           snippet: "Private meta-search for Elektrine",
           score: 5
         }
       ]}
    end
  end

  setup do
    previous_providers = Application.get_env(:maid, :providers, [])

    Application.put_env(:maid, :providers, [SearchProvider])

    on_exit(fn -> Application.put_env(:maid, :providers, previous_providers) end)

    :ok
  end

  test "renders Maid from the main navigation", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/maid")

    assert html =~ "Maid"
    assert html =~ "Private, ad-free web search"
    assert html =~ "Web Search"
    assert html =~ "Search"
    assert html =~ ~s(href="/maid")
  end

  test "runs configured Maid providers from query params", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/maid?q=meta")

    assert html =~ "Maid meta-search"
    assert html =~ "https://maid.example/search"
    assert html =~ "Private meta-search for Elektrine"
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
