defmodule Elektrine.Social.ReplyCountsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  test "remote post replies add local replies to the remote baseline" do
    user = user_fixture()

    parent =
      post_fixture()
      |> Ecto.Changeset.change(
        reply_count: 1,
        media_metadata: %{"original_reply_count" => 20}
      )
      |> Repo.update!()

    {:ok, _reply} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: parent.conversation_id,
        sender_id: user.id,
        content: "local reply",
        message_type: "text",
        visibility: "public",
        post_type: "post",
        reply_to_id: parent.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    Social.increment_reply_count(parent.id)

    assert %Message{reply_count: 21} = Repo.get!(Message, parent.id)
  end
end
