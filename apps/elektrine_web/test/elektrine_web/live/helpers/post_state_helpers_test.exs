defmodule ElektrineWeb.Live.Helpers.PostStateHelpersTest do
  use Elektrine.DataCase, async: false

  import Elektrine.SocialFixtures, only: [post_fixture: 1]

  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias ElektrineWeb.Live.Helpers.PostStateHelpers

  test "user interaction state includes loaded shared messages" do
    author = AccountsFixtures.user_fixture()
    booster = AccountsFixtures.user_fixture()
    viewer = AccountsFixtures.user_fixture()
    original = post_fixture(%{user: author, content: "Shared post state"})

    assert {:ok, _boost} = Elektrine.Social.boost_post(booster.id, original.id)
    assert {:ok, _like} = Elektrine.Social.like_post(viewer.id, original.id)
    assert {:ok, _viewer_boost} = Elektrine.Social.boost_post(viewer.id, original.id)
    assert {:ok, _save} = Elektrine.Social.save_post(viewer.id, original.id)

    wrapper =
      Repo.get_by!(Message, sender_id: booster.id, shared_message_id: original.id)
      |> Repo.preload(:shared_message)

    likes = PostStateHelpers.get_user_likes(viewer.id, [wrapper])
    boosts = PostStateHelpers.get_user_boosts(viewer.id, [wrapper])
    saves = PostStateHelpers.get_user_saves(viewer.id, [wrapper])

    assert likes[original.id]
    assert boosts[original.id]
    assert saves[original.id]
    refute likes[wrapper.id]
    refute boosts[wrapper.id]
    refute saves[wrapper.id]
  end
end
