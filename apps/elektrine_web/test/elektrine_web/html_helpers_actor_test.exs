defmodule ElektrineWeb.HtmlHelpersActorTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias ElektrineWeb.HtmlHelpers

  test "render_actor_display_name renders custom emojis for remote actors" do
    %CustomEmoji{}
    |> CustomEmoji.changeset(%{
      shortcode: "blobcat",
      image_url: "https://remote.example/emoji/blobcat.png",
      instance_domain: "remote.example",
      visible_in_picker: false,
      disabled: false
    })
    |> Repo.insert!()

    html =
      HtmlHelpers.render_actor_display_name(%{
        display_name: "Alice :blobcat:",
        username: "alice",
        domain: "remote.example"
      })

    assert html =~ "Alice"
    assert html =~ "custom-emoji"
    assert html =~ "blobcat.png"
  end

  test "actor_display_name_text falls back from url-like display names to username" do
    actor = %{
      display_name: "https://example.com/remote/zero@strelizia.net",
      username: "zero",
      domain: "strelizia.net"
    }

    assert HtmlHelpers.actor_display_name_text(actor) == "zero"
    assert HtmlHelpers.render_actor_display_name(actor) == "zero"
  end

  test "render_remote_post_content links local fediverse handles to local profiles" do
    user = AccountsFixtures.user_fixture(%{username: "maxfield"})

    html =
      HtmlHelpers.render_remote_post_content(
        "Hello @maxfield@#{ActivityPub.instance_domain()}",
        "remote.example"
      )

    assert html =~ ~s(href="/#{user.handle}")
    assert html =~ "@maxfield@#{ActivityPub.instance_domain()}"
    refute html =~ ~s(phx-click="stop_propagation")
  end

  test "render_remote_post_content keeps remote fediverse handles on remote routes" do
    html =
      HtmlHelpers.render_remote_post_content(
        "Hello @alice@mastodon.social",
        "remote.example"
      )

    assert html =~ ~s(href="/remote/alice@mastodon.social")
    assert html =~ "@alice@mastodon.social"
  end

  test "render_remote_post_content links short mentions using the origin domain" do
    html =
      HtmlHelpers.render_remote_post_content(
        "<p>Hello @alice</p>",
        "mastodon.social"
      )

    assert html =~ ~s(href="/remote/alice@mastodon.social")
    assert html =~ ">@alice</a>"
    refute html =~ ~s(phx-click="stop_propagation")
  end

  test "render_remote_post_content links plain-text fediverse mentions in fallback output" do
    html =
      HtmlHelpers.render_remote_post_content(
        "@whitequark@social.treehouse.systems\n\nWhen I started using FreeBSD",
        "infosec.exchange"
      )

    assert html =~ ~s(href="/remote/whitequark@social.treehouse.systems")
    assert html =~ ">@whitequark@social.treehouse.systems</a>"
    refute html =~ ~s(phx-click="stop_propagation")
  end

  test "render_remote_post_content decodes doubly-encoded apostrophes" do
    html =
      HtmlHelpers.render_remote_post_content(
        "As an American, I gotta ask if it&amp;#39;s possible to switch",
        "beige.party"
      )

    assert html =~ "it&#39;s possible to switch"
    refute html =~ "/hashtag/39"
    refute html =~ "&amp;#39;"
  end

  test "render_remote_post_content does not partially link domain-style non-fedi handles" do
    html = HtmlHelpers.render_remote_post_content("<p>Hello @x.com</p>", "mastodon.social")

    assert html =~ "@x.com"
    refute html =~ ~s(href="/remote/x@mastodon.social")
    refute html =~ ~s(href="/x")
  end

  test "render_remote_post_content links alex at x to the x profile" do
    html = HtmlHelpers.render_remote_post_content("<p>Hello alex@x.com</p>", "mastodon.social")

    assert html =~ ~s(href="https://x.com/alex")
    assert html =~ ">alex@x.com</a>"
  end

  test "make_content_safe_with_links links alex at x to the x profile" do
    html = HtmlHelpers.make_content_safe_with_links("Hello alex@x.com")

    assert html =~ ~s(href="https://x.com/alex")
    assert html =~ ">alex@x.com</a>"
  end

  test "render_post_content prefers reply-author domain for short mentions" do
    html =
      HtmlHelpers.render_post_content(%{
        content: "<p>@JackTheCat lool</p>",
        remote_actor: %Actor{domain: "mastodon.online"},
        media_metadata: %{"inReplyToAuthor" => "@JackTheCat@mastodon.scot"},
        reply_to: %{
          remote_actor: %Actor{username: "JackTheCat", domain: "mastodon.scot"}
        }
      })

    assert html =~ ~s(href="/remote/JackTheCat@mastodon.scot")
    refute html =~ ~s(/remote/JackTheCat@mastodon.online)
    assert html =~ ">@JackTheCat</a>"
  end

  test "render_post_content prefers loaded reply target domain for short mentions" do
    html =
      HtmlHelpers.render_post_content(%{
        content: "<p>@JackTheCat lool</p>",
        remote_actor: %Actor{domain: "mastodon.online"},
        reply_to: %{
          remote_actor: %Actor{username: "JackTheCat", domain: "mastodon.scot"}
        }
      })

    assert html =~ ~s(href="/remote/JackTheCat@mastodon.scot")
    refute html =~ ~s(/remote/JackTheCat@mastodon.online)
  end
end
