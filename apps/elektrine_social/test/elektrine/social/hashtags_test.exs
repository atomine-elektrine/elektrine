defmodule Elektrine.Social.HashtagsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Social.Hashtag
  alias Elektrine.Social.Hashtags

  describe "get_or_create_hashtag/1" do
    test "is safe when the same tag is created concurrently" do
      hashtags =
        1..20
        |> Task.async_stream(fn _ -> Hashtags.get_or_create_hashtag("infosec") end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, hashtag} -> hashtag end)

      assert Enum.all?(hashtags, &match?(%Hashtag{normalized_name: "infosec"}, &1))

      assert 1 ==
               Repo.aggregate(
                 from(h in Hashtag, where: h.normalized_name == "infosec"),
                 :count
               )
    end

    test "normalizes leading hash and rejects invalid names" do
      assert %Hashtag{name: "InfoSec", normalized_name: "infosec"} =
               Hashtags.get_or_create_hashtag(" #InfoSec ")

      assert is_nil(Hashtags.get_or_create_hashtag("bad tag"))
    end
  end
end
