defmodule ElektrineWeb.API.ScrobbleControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Social.Scrobbles
  alias ElektrineWeb.Plugs.APIAuth

  import Elektrine.AccountsFixtures

  describe "create/2" do
    test "creates a listen record for the authenticated user", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/pleroma/scrobble", %{
          "title" => "Duvet",
          "artist" => "Boa",
          "album" => "The Race of a Thousand Camels",
          "length" => 203_000,
          "externalLink" => "https://music.example/tracks/duvet"
        })

      assert %{
               "id" => id,
               "title" => "Duvet",
               "artist" => "Boa",
               "album" => "The Race of a Thousand Camels",
               "length" => 203_000,
               "external_link" => "https://music.example/tracks/duvet",
               "account" => %{"id" => user_id}
             } = json_response(conn, 200)

      assert is_binary(id)
      assert user_id == to_string(user.id)
    end

    test "rejects missing title", %{conn: conn} do
      user = user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/pleroma/scrobble", %{"artist" => "No Title"})

      assert %{
               "error" => "invalid_scrobble",
               "details" => %{"title" => [_ | _]}
             } = json_response(conn, 400)
    end
  end

  describe "index/2" do
    test "lists public and unlisted records for a local account", %{conn: conn} do
      user = user_fixture()

      {:ok, public} = Scrobbles.create_scrobble(user, %{"title" => "Public Track"})

      {:ok, unlisted} =
        Scrobbles.create_scrobble(user, %{"title" => "Unlisted Track", "visibility" => "unlisted"})

      {:ok, _private} =
        Scrobbles.create_scrobble(user, %{"title" => "Private Track", "visibility" => "private"})

      conn = get(conn, "/api/v1/pleroma/accounts/#{user.id}/scrobbles")

      ids = Enum.map(json_response(conn, 200), & &1["id"])

      assert to_string(unlisted.id) in ids
      assert to_string(public.id) in ids
      assert length(ids) == 2
    end

    test "supports username lookup and pagination params", %{conn: conn} do
      user = user_fixture(%{username: "musicuser"})

      {:ok, older} = Scrobbles.create_scrobble(user, %{"title" => "Older"})
      {:ok, newer} = Scrobbles.create_scrobble(user, %{"title" => "Newer"})

      conn =
        get(conn, "/api/v1/pleroma/accounts/#{user.username}/scrobbles", %{"max_id" => newer.id})

      assert [%{"id" => id, "title" => "Older"}] = json_response(conn, 200)
      assert id == to_string(older.id)
    end

    test "returns 404 for missing accounts", %{conn: conn} do
      conn = get(conn, "/api/v1/pleroma/accounts/notfound/scrobbles")

      assert %{"error" => "account not found"} = json_response(conn, 404)
    end
  end
end
