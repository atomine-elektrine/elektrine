defmodule Elektrine.Social.RecommendationRefreshWorkerTest do
  use Elektrine.DataCase, async: true
  use Oban.Testing, repo: Elektrine.Repo

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social.{RecommendationItem, RecommendationRefreshWorker}

  test "refresh worker persists ranked recommendation rows" do
    viewer = user_fixture()
    author = user_fixture()
    post = post_fixture(%{user: author, content: "worker rec #{System.unique_integer()}"})

    assert :ok =
             RecommendationRefreshWorker.perform(%Oban.Job{
               args: %{"user_id" => viewer.id, "filter" => "all", "limit" => 20}
             })

    assert Repo.exists?(
             from(i in RecommendationItem,
               where: i.user_id == ^viewer.id and i.message_id == ^post.id and i.filter == "all"
             )
           )
  end

  test "enqueue stores refresh jobs by user and filter in manual mode" do
    viewer = user_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} = RecommendationRefreshWorker.enqueue(viewer.id, filter: "timeline")

      assert [
               %Oban.Job{
                 args: %{"user_id" => user_id, "filter" => "timeline", "limit" => 100}
               }
             ] = all_enqueued(worker: RecommendationRefreshWorker)

      assert user_id == viewer.id
    end)
  end
end
