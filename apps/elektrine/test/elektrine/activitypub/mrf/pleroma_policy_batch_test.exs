defmodule Elektrine.ActivityPub.MRF.PleromaPolicyBatchTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub

  alias Elektrine.ActivityPub.MRF.{
    AntiLinkSpamPolicy,
    AntiMentionSpamPolicy,
    EmojiPolicy,
    ForceBotUnlistedPolicy,
    HashtagPolicy,
    InlineQuotePolicy,
    MentionPolicy,
    NoEmptyPolicy,
    NoPlaceholderTextPolicy,
    QuietReplyPolicy,
    QuoteToLinkTagPolicy,
    RejectNonPublicPolicy,
    RemoteReportPolicy,
    UserAllowListPolicy,
    VocabularyPolicy
  }

  setup do
    Enum.each(
      [
        :mrf_emoji,
        :mrf_hashtag,
        :mrf_inline_quote,
        :mrf_mention,
        :mrf_reject_non_public,
        :mrf_remote_report,
        :mrf_user_allowlist,
        :mrf_vocabulary
      ],
      &Application.delete_env(:elektrine, &1)
    )

    :ok
  end

  test "NoPlaceholderTextPolicy removes dot filler from media posts" do
    activity = create_activity(%{"content" => ".", "attachment" => [%{"type" => "Image"}]})

    assert {:ok, filtered} = NoPlaceholderTextPolicy.filter(activity)
    assert filtered["object"]["content"] == ""
  end

  test "NoEmptyPolicy rejects local notes with only mentions" do
    activity =
      create_activity(%{
        "actor" => "#{ActivityPub.instance_url()}/users/alice",
        "content" => "@bob @carol",
        "source" => "@bob @carol"
      })

    assert {:reject, "[NoEmptyPolicy] empty local note"} = NoEmptyPolicy.filter(activity)
  end

  test "RejectNonPublicPolicy rejects followers-only posts unless allowed" do
    activity =
      create_activity(%{
        "actor" => "https://remote.example/users/alice",
        "to" => ["https://remote.example/users/alice/followers"],
        "cc" => []
      })

    assert {:reject, "[RejectNonPublicPolicy] followers-only activity rejected"} =
             RejectNonPublicPolicy.filter(activity)

    Application.put_env(:elektrine, :mrf_reject_non_public, allow_followers_only: true)

    assert {:ok, ^activity} = RejectNonPublicPolicy.filter(activity)
  end

  test "VocabularyPolicy rejects disallowed activity and object types" do
    Application.put_env(:elektrine, :mrf_vocabulary, accept: ["Create", "Note"])

    assert {:ok, _} = VocabularyPolicy.filter(create_activity())

    assert {:reject, "[VocabularyPolicy] Like not in accept list"} =
             VocabularyPolicy.filter(%{"type" => "Like", "object" => "x"})

    Application.put_env(:elektrine, :mrf_vocabulary, reject: ["Question"])

    assert {:reject, "[VocabularyPolicy] Question in reject list"} =
             VocabularyPolicy.filter(create_activity(%{"type" => "Question"}))
  end

  test "QuietReplyPolicy converts local public replies to unlisted" do
    actor = "#{ActivityPub.instance_url()}/users/alice"

    activity =
      create_activity(%{
        "actor" => actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "inReplyTo" => "https://remote.example/notes/1"
      })

    assert {:ok, filtered} = QuietReplyPolicy.filter(activity)
    refute "https://www.w3.org/ns/activitystreams#Public" in filtered["to"]
    assert "https://www.w3.org/ns/activitystreams#Public" in filtered["cc"]
    assert "#{actor}/followers" in filtered["to"]
  end

  test "HashtagPolicy rejects delists and marks sensitive by hashtag" do
    Application.put_env(:elektrine, :mrf_hashtag,
      reject: ["spam"],
      federated_timeline_removal: ["politics"],
      sensitive: ["nsfw"]
    )

    assert {:reject, "[HashtagPolicy] rejected hashtag"} =
             HashtagPolicy.filter(create_activity(%{"content" => "bad #spam"}))

    assert {:ok, delisted} =
             HashtagPolicy.filter(create_activity(%{"content" => "talking #politics"}))

    refute "https://www.w3.org/ns/activitystreams#Public" in delisted["to"]
    assert "https://www.w3.org/ns/activitystreams#Public" in delisted["cc"]

    assert {:ok, sensitive} =
             HashtagPolicy.filter(create_activity(%{"content" => "image #nsfw"}))

    assert sensitive["object"]["sensitive"] == true
  end

  test "EmojiPolicy removes blocked custom emoji and rejects blocked reactions" do
    Application.put_env(:elektrine, :mrf_emoji,
      remove_shortcode: ["badmoji"],
      federated_timeline_removal_shortcode: ["loudmoji"]
    )

    activity =
      create_activity(%{
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":badmoji:",
            "icon" => %{"url" => "https://emoji.example/bad.png"}
          },
          %{
            "type" => "Emoji",
            "name" => ":ok:",
            "icon" => %{"url" => "https://emoji.example/ok.png"}
          }
        ],
        "emoji" => %{
          "badmoji" => "https://emoji.example/bad.png",
          "ok" => "https://emoji.example/ok.png"
        }
      })

    assert {:ok, filtered} = EmojiPolicy.filter(activity)
    assert Enum.map(filtered["object"]["tag"], & &1["name"]) == [":ok:"]
    assert filtered["object"]["emoji"] == %{"ok" => "https://emoji.example/ok.png"}

    assert {:ok, delisted} =
             EmojiPolicy.filter(
               create_activity(%{
                 "tag" => [%{"type" => "Emoji", "name" => ":loudmoji:"}]
               })
             )

    refute "https://www.w3.org/ns/activitystreams#Public" in delisted["to"]

    assert {:reject, "[EmojiPolicy] rejected emoji reaction"} =
             EmojiPolicy.filter(%{
               "type" => "EmojiReact",
               "tag" => [%{"type" => "Emoji", "name" => ":badmoji:"}]
             })
  end

  test "RemoteReportPolicy rejects low-quality remote reports" do
    Application.put_env(:elektrine, :mrf_remote_report,
      reject_anonymous: true,
      reject_third_party: true,
      reject_empty_message: true
    )

    assert {:reject, "[RemoteReportPolicy] anonymous remote report rejected"} =
             RemoteReportPolicy.filter(%{
               "type" => "Flag",
               "actor" => "https://remote.example/actor",
               "object" => "#{ActivityPub.instance_url()}/users/alice",
               "content" => "bad"
             })

    assert {:reject, "[RemoteReportPolicy] third-party report rejected"} =
             RemoteReportPolicy.filter(%{
               "type" => "Flag",
               "actor" => "https://remote.example/users/bob",
               "object" => "https://third.example/users/alice",
               "content" => "bad"
             })

    assert {:reject, "[RemoteReportPolicy] empty remote report rejected"} =
             RemoteReportPolicy.filter(%{
               "type" => "Flag",
               "actor" => "https://remote.example/users/bob",
               "object" => "#{ActivityPub.instance_url()}/users/alice",
               "content" => ""
             })
  end

  test "MentionPolicy rejects posts mentioning protected actors" do
    protected = "#{ActivityPub.instance_url()}/users/alice"
    Application.put_env(:elektrine, :mrf_mention, actors: [protected])

    activity = create_activity(%{"to" => [protected]})
    expected = "[MentionPolicy] rejected mention of #{protected}"

    assert {:reject, ^expected} = MentionPolicy.filter(activity)
  end

  test "UserAllowListPolicy restricts configured domains to explicit actors" do
    allowed = "https://remote.example/users/allowed"
    denied = "https://remote.example/users/denied"

    Application.put_env(:elektrine, :mrf_user_allowlist, hosts: %{"remote.example" => [allowed]})

    assert {:ok, _} = UserAllowListPolicy.filter(create_activity(%{"actor" => allowed}))

    expected = "[UserAllowListPolicy] #{denied} not in allowlist for remote.example"

    assert {:reject, ^expected} =
             UserAllowListPolicy.filter(create_activity(%{"actor" => denied}))
  end

  test "UserAllowListPolicy does not create atoms for remote actor hosts" do
    host = "untrusted-#{System.unique_integer([:positive])}.example"

    Application.put_env(:elektrine, :mrf_user_allowlist, hosts: [])

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(host, :utf8)
    end

    assert {:ok, _} =
             UserAllowListPolicy.filter(
               create_activity(%{"actor" => "https://#{host}/users/alice"})
             )

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(host, :utf8)
    end
  end

  test "ForceBotUnlistedPolicy removes public delivery from likely bot posts" do
    activity =
      create_activity(%{
        "actor" => "https://remote.example/users/news.bot",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      })

    assert {:ok, filtered} = ForceBotUnlistedPolicy.filter(activity)
    refute "https://www.w3.org/ns/activitystreams#Public" in filtered["to"]
    assert "https://www.w3.org/ns/activitystreams#Public" in filtered["cc"]
  end

  test "Quote policies add compatibility tag and inline quote content" do
    quote_url = "https://remote.example/notes/quoted"
    activity = create_activity(%{"quoteUrl" => quote_url, "content" => "<p>quoted this</p>"})

    assert {:ok, tagged} = QuoteToLinkTagPolicy.filter(activity)
    assert Enum.any?(tagged["object"]["tag"], &(&1["type"] == "Link" and &1["href"] == quote_url))

    Application.put_env(:elektrine, :mrf_inline_quote, template: "RE: {url}")

    assert {:ok, inlined} = InlineQuotePolicy.filter(activity)
    assert inlined["object"]["content"] =~ "quote-inline"
    assert inlined["object"]["content"] =~ quote_url
  end

  test "AntiLinkSpamPolicy rejects links from unknown remote actors" do
    activity =
      create_activity(%{
        "actor" => "https://fresh.example/users/alice",
        "content" => ~s(<p>look <a href="https://spam.example">here</a></p>)
      })

    assert {:reject, "[AntiLinkSpamPolicy] unknown remote actor posted links"} =
             AntiLinkSpamPolicy.filter(activity)
  end

  test "AntiMentionSpamPolicy rejects mentions from unknown remote actors" do
    activity =
      create_activity(%{
        "actor" => "https://fresh.example/users/alice",
        "to" => ["#{ActivityPub.instance_url()}/users/bob"],
        "cc" => []
      })

    assert {:reject, "[AntiMentionSpamPolicy] unknown remote actor mentioned users"} =
             AntiMentionSpamPolicy.filter(activity)
  end

  defp create_activity(overrides \\ %{}) do
    actor = Map.get(overrides, "actor", "https://remote.example/users/alice")
    to = Map.get(overrides, "to", ["https://www.w3.org/ns/activitystreams#Public"])
    cc = Map.get(overrides, "cc", [])
    object_overrides = Map.drop(overrides, ["actor", "to", "cc"])

    object =
      Map.merge(
        %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "actor" => actor,
          "attributedTo" => actor,
          "content" => "hello",
          "to" => to,
          "cc" => cc
        },
        object_overrides
      )

    %{
      "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor,
      "to" => to,
      "cc" => cc,
      "object" => object
    }
  end
end
