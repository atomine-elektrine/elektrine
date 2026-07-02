defmodule ElektrineWeb.API.PollControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Poll
  alias ElektrineWeb.API.PollController

  describe "show/2" do
    test "returns a visible poll", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})
      {:ok, poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])

      conn =
        conn
        |> assign(:current_user, viewer)
        |> PollController.show(%{"id" => to_string(poll.id)})

      assert %{
               "id" => id,
               "expired" => false,
               "multiple" => false,
               "options" => [
                 %{"title" => "One", "votes_count" => 0},
                 %{"title" => "Two", "votes_count" => 0}
               ],
               "voted" => false,
               "emojis" => [],
               "pleroma" => %{"non_anonymous" => false}
             } = json_response(conn, 200)

      assert id == to_string(poll.id)
    end

    test "hides totals before the viewer votes when configured", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})

      {:ok, poll} =
        Social.create_poll(post.id, "Hidden totals?", ["Yes", "No"], hide_totals: true)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> PollController.show(%{"id" => poll.id})

      assert %{
               "votes_count" => nil,
               "voters_count" => nil,
               "options" => [%{"votes_count" => nil}, %{"votes_count" => nil}]
             } = json_response(conn, 200)
    end
  end

  describe "vote/2" do
    test "sets votes idempotently", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})
      {:ok, poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])
      [option, _] = poll.options

      conn =
        conn
        |> assign(:current_user, viewer)
        |> PollController.vote(%{
          "id" => to_string(poll.id),
          "choices" => [to_string(option.id)]
        })

      assert %{"own_votes" => [option_id], "voted" => true, "votes_count" => 1} =
               json_response(conn, 200)

      assert option_id == to_string(option.id)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> PollController.vote(%{
          "id" => to_string(poll.id),
          "choices" => [to_string(option.id)]
        })

      assert %{"own_votes" => [^option_id], "votes_count" => 1} = json_response(conn, 200)
    end

    test "rejects voting on your own poll", %{conn: conn} do
      author = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})
      {:ok, poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])
      [option, _] = poll.options

      conn =
        conn
        |> assign(:current_user, author)
        |> PollController.vote(%{"id" => poll.id, "choices" => [option.id]})

      assert %{"error" => "cannot vote on your own poll"} = json_response(conn, 422)
    end

    test "returns totals after voting on a hidden-total poll", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})

      {:ok, poll} =
        Social.create_poll(post.id, "Hidden totals?", ["Yes", "No"], hide_totals: true)

      [option, _] = poll.options

      conn =
        conn
        |> assign(:current_user, viewer)
        |> PollController.vote(%{"id" => poll.id, "choices" => [option.id]})

      assert %{
               "votes_count" => 1,
               "voters_count" => 1,
               "options" => [%{"votes_count" => 1}, %{"votes_count" => 0}]
             } = json_response(conn, 200)
    end
  end

  describe "delete_votes/2" do
    test "clears current user's votes", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public"})
      {:ok, poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])
      [option, _] = poll.options
      {:ok, _poll} = Social.set_poll_votes(poll.id, [option.id], viewer.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> PollController.delete_votes(%{"id" => poll.id})

      assert %{"own_votes" => [], "voted" => false, "votes_count" => 0} =
               json_response(conn, 200)

      assert Repo.get!(Poll, poll.id).total_votes == 0
    end
  end
end
