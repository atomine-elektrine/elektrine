defmodule Elektrine.Social.TimelineLoadVerifierTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Social.TimelineLoadVerifier

  describe "run/1" do
    test "seeds and verifies combined feed pagination order" do
      prefix = "tlv#{System.unique_integer([:positive])}"

      assert {:ok, summary} =
               TimelineLoadVerifier.run(
                 count: 45,
                 page_size: 20,
                 prefix: prefix
               )

      assert summary.seeded_count == 45
      assert summary.expected_count == 45
      assert summary.found_count == 45
      assert summary.loaded_count == 45
      assert summary.pages_checked == 3
      assert summary.viewer_username != summary.author_username
      assert summary.first_id > summary.last_id
    end
  end

  describe "verify_existing/3" do
    test "rejects empty expected ids" do
      user = user_fixture()

      assert {:error, %{reason: :no_expected_ids}} =
               TimelineLoadVerifier.verify_existing(user.id, [])
    end

    test "reports expected ids that are not reachable" do
      user = user_fixture()

      assert {:error, %{reason: :missing_seeded_posts, missing_ids: [9_999_999]}} =
               TimelineLoadVerifier.verify_existing(user.id, [9_999_999],
                 page_size: 5,
                 max_pages: 1
               )
    end
  end
end
