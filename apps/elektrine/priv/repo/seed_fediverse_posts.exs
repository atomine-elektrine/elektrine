alias Elektrine.{Messaging, Repo}
alias Elektrine.ActivityPub.Actor
alias Elektrine.Social.{Message, Poll, PollOption}

import Ecto.Query

unless Mix.env() == :dev do
  raise "seed_fediverse_posts.exs is intended for development only"
end

now = DateTime.utc_now() |> DateTime.truncate(:second)
ago = fn seconds -> DateTime.add(now, -seconds, :second) |> DateTime.truncate(:second) end
from_now = fn seconds -> DateTime.add(now, seconds, :second) |> DateTime.truncate(:second) end

ensure_actor = fn attrs ->
  case Repo.get_by(Actor, uri: attrs.uri) do
    nil ->
      %Actor{}
      |> Actor.changeset(attrs)
      |> Repo.insert!()

    actor ->
      actor
      |> Actor.changeset(attrs)
      |> Repo.update!()
  end
end

ensure_post = fn actor, attrs ->
  attrs =
    attrs
    |> Map.merge(%{
      remote_actor_id: actor.id,
      federated: true,
      visibility: Map.get(attrs, :visibility, "public"),
      media_metadata: Map.get(attrs, :media_metadata, %{}),
      like_count: Map.get(attrs, :like_count, 0),
      reply_count: Map.get(attrs, :reply_count, 0),
      share_count: Map.get(attrs, :share_count, 0),
      quote_count: Map.get(attrs, :quote_count, 0),
      upvotes: Map.get(attrs, :upvotes, 0),
      downvotes: Map.get(attrs, :downvotes, 0),
      score: Map.get(attrs, :score, 0)
    })

  case Messaging.get_message_by_activitypub_ref(attrs.activitypub_id) do
    nil ->
      {:ok, message} = Messaging.create_federated_message(attrs)
      message

    %Message{} = message ->
      message
      |> Message.federated_changeset(attrs)
      |> Repo.update!()
  end
end

ensure_poll = fn message, attrs ->
  poll =
    case Repo.preload(message, [poll: [:options]], force: true).poll do
      nil ->
        %Poll{}
        |> Poll.changeset(%{
          message_id: message.id,
          question: attrs.question,
          closes_at: attrs.closes_at,
          allow_multiple: Map.get(attrs, :allow_multiple, false),
          hide_totals: Map.get(attrs, :hide_totals, false),
          total_votes: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end),
          voters_count: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end),
          last_fetched_at: now
        })
        |> Repo.insert!()

      existing ->
        existing
        |> Poll.changeset(%{
          question: attrs.question,
          closes_at: attrs.closes_at,
          allow_multiple: Map.get(attrs, :allow_multiple, false),
          hide_totals: Map.get(attrs, :hide_totals, false),
          total_votes: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end),
          voters_count: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end),
          last_fetched_at: now
        })
        |> Repo.update!()
    end

  from(option in PollOption, where: option.poll_id == ^poll.id)
  |> Repo.delete_all()

  attrs.options
  |> Enum.with_index()
  |> Enum.each(fn {{option_text, vote_count}, position} ->
    %PollOption{}
    |> PollOption.changeset(%{
      poll_id: poll.id,
      option_text: option_text,
      position: position,
      vote_count: vote_count
    })
    |> Repo.insert!()
  end)

  Repo.preload(poll, :options, force: true)
end

pollbot =
  ensure_actor.(%{
    uri: "https://mastodon.seed.local/users/pollbot",
    username: "pollbot",
    domain: "mastodon.seed.local",
    display_name: "Poll Bot",
    summary: "Development seed bot for federated timeline and remote profile testing.",
    avatar_url: "/images/mark.png",
    header_url: "/images/z1.png",
    inbox_url: "https://mastodon.seed.local/users/pollbot/inbox",
    outbox_url: "https://mastodon.seed.local/users/pollbot/outbox",
    followers_url: "https://mastodon.seed.local/users/pollbot/followers",
    following_url: "https://mastodon.seed.local/users/pollbot/following",
    public_key: "seed-dev-public-key-pollbot",
    actor_type: "Person",
    published_at: ago.(90 * 86_400),
    metadata: %{"followers" => 428, "following" => 12, "statuses_count" => 42}
  })

photobot =
  ensure_actor.(%{
    uri: "https://pixelfed.seed.local/users/photobot",
    username: "photobot",
    domain: "pixelfed.seed.local",
    display_name: "Photo Bot",
    summary: "Pixelfed-style media actor seeded for gallery and media-card testing.",
    avatar_url: "/images/c1.png",
    header_url: "/images/e1.png",
    inbox_url: "https://pixelfed.seed.local/users/photobot/inbox",
    outbox_url: "https://pixelfed.seed.local/users/photobot/outbox",
    followers_url: "https://pixelfed.seed.local/users/photobot/followers",
    following_url: "https://pixelfed.seed.local/users/photobot/following",
    public_key: "seed-dev-public-key-photobot",
    actor_type: "Person",
    published_at: ago.(120 * 86_400),
    metadata: %{"followers" => 981, "following" => 34, "statuses_count" => 87}
  })

threadbot =
  ensure_actor.(%{
    uri: "https://pleroma.seed.local/users/threadbot",
    username: "threadbot",
    domain: "pleroma.seed.local",
    display_name: "Thread Bot",
    summary: "Pleroma-style actor for reply/thread rendering smoke tests.",
    avatar_url: "/images/e1.png",
    header_url: "/images/c1.png",
    inbox_url: "https://pleroma.seed.local/users/threadbot/inbox",
    outbox_url: "https://pleroma.seed.local/users/threadbot/outbox",
    followers_url: "https://pleroma.seed.local/users/threadbot/followers",
    following_url: "https://pleroma.seed.local/users/threadbot/following",
    public_key: "seed-dev-public-key-threadbot",
    actor_type: "Person",
    published_at: ago.(45 * 86_400),
    metadata: %{"followers" => 217, "following" => 19, "statuses_count" => 31}
  })

poll_post =
  ensure_post.(pollbot, %{
    activitypub_id: "https://mastodon.seed.local/users/pollbot/statuses/seed-timeline-poll-1",
    activitypub_url: "https://mastodon.seed.local/@pollbot/seed-timeline-poll-1",
    post_type: "poll",
    content: "Seeded remote poll for federated timeline smoke tests. #seedfediverse #polls",
    extracted_hashtags: ["seedfediverse", "polls"],
    inserted_at: ago.(900),
    like_count: 8,
    reply_count: 2,
    share_count: 3
  })

ensure_poll.(poll_post, %{
  question: "Which remote timeline surface should get the most test coverage?",
  options: [{"Profile sticky actions", 7}, {"Federated media cards", 5}, {"Remote replies", 3}],
  closes_at: from_now.(3 * 86_400)
})

text_post =
  ensure_post.(pollbot, %{
    activitypub_id: "https://mastodon.seed.local/users/pollbot/statuses/seed-fediverse-note-1",
    activitypub_url: "https://mastodon.seed.local/@pollbot/seed-fediverse-note-1",
    post_type: "post",
    content:
      "Remote seed note from Mastodon: testing profile sticky follow, federated filtering, and actor cards. #seedfediverse",
    extracted_hashtags: ["seedfediverse"],
    inserted_at: ago.(1_800),
    like_count: 14,
    reply_count: 2,
    share_count: 4
  })

ensure_post.(threadbot, %{
  activitypub_id: "https://pleroma.seed.local/users/threadbot/statuses/reply-to-pollbot-1",
  activitypub_url: "https://pleroma.seed.local/notice/reply-to-pollbot-1",
  post_type: "post",
  content:
    "Replying from a different seeded remote actor so thread previews have federated context.",
  reply_to_id: text_post.id,
  media_metadata: %{"inReplyTo" => text_post.activitypub_id},
  inserted_at: ago.(1_650),
  like_count: 3
})

ensure_post.(photobot, %{
  activitypub_id: "https://pixelfed.seed.local/users/photobot/statuses/seed-media-1",
  activitypub_url: "https://pixelfed.seed.local/p/photobot/seed-media-1",
  post_type: "gallery",
  message_type: "image",
  content:
    "Pixelfed-style remote media seed. This should exercise image cards and remote profile media. #seedfediverse #media",
  media_urls: ["/images/z1.png", "/images/c1.png"],
  media_metadata: %{
    "attachments" => [
      %{"type" => "Image", "url" => "/images/z1.png", "name" => "Seed media image one"},
      %{"type" => "Image", "url" => "/images/c1.png", "name" => "Seed media image two"}
    ]
  },
  extracted_hashtags: ["seedfediverse", "media"],
  inserted_at: ago.(3_000),
  like_count: 22,
  reply_count: 1,
  share_count: 6
})

ensure_post.(threadbot, %{
  activitypub_id: "https://pleroma.seed.local/users/threadbot/statuses/seed-cw-1",
  activitypub_url: "https://pleroma.seed.local/notice/seed-cw-1",
  post_type: "post",
  content:
    "This seeded remote post has a content warning so spoiler/cw rendering can be checked in the timeline.",
  content_warning: "Seeded CW example",
  sensitive: true,
  inserted_at: ago.(4_200),
  like_count: 5,
  reply_count: 0,
  share_count: 1
})

ensure_post.(threadbot, %{
  activitypub_id: "https://pleroma.seed.local/users/threadbot/statuses/seed-link-1",
  activitypub_url: "https://pleroma.seed.local/notice/seed-link-1",
  post_type: "link",
  content: "Remote link-style post for layout testing: https://example.com/fediverse-seed",
  primary_url: "https://example.com/fediverse-seed",
  media_metadata: %{"type" => "Article"},
  inserted_at: ago.(5_400),
  like_count: 9,
  reply_count: 1,
  share_count: 2
})

federated_count = Repo.aggregate(from(m in Message, where: m.federated == true), :count, :id)

seed_count =
  Repo.aggregate(
    from(m in Message, where: m.federated == true and like(m.activitypub_id, "%seed%")),
    :count,
    :id
  )

IO.puts(
  "✓ Seeded fediverse actors: @pollbot@mastodon.seed.local, @photobot@pixelfed.seed.local, @threadbot@pleroma.seed.local"
)

IO.puts(
  "✓ Seeded #{seed_count} seed federated messages (#{federated_count} federated messages total)"
)

IO.puts("  Test URLs:")
IO.puts("  - /timeline?filter=federated")
IO.puts("  - /remote/pollbot@mastodon.seed.local")
IO.puts("  - /remote/photobot@pixelfed.seed.local")
IO.puts("  - /remote/threadbot@pleroma.seed.local")
