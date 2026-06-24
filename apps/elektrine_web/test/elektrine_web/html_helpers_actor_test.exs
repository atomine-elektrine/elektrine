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

  test "render_remote_post_content links hyphenated remote fediverse handles" do
    html =
      HtmlHelpers.render_remote_post_content(
        "@lait-accompli@shitposter.world what looks modern though?",
        "pleroma.soykaf.com"
      )

    assert html =~ ~s(href="/remote/lait-accompli@shitposter.world")
    assert html =~ ">@lait-accompli@shitposter.world</a>"
    refute html =~ ~s(href="/remote/lait@pleroma.soykaf.com")
  end

  test "safe_basic_html strips private-network image sources" do
    html =
      HtmlHelpers.safe_basic_html(
        ~s(<p>Hello</p><img src="http://127.0.0.1/admin.png" alt="local">)
      )

    assert html =~ "<img"
    refute html =~ "127.0.0.1"
    refute html =~ ~s(src=)
  end

  test "render_markdown_images does not emit private-network image sources" do
    html = HtmlHelpers.render_markdown_images("![local](http://127.0.0.1/pictrs/image/a.png)")

    refute html =~ "<img"
    refute html =~ "127.0.0.1"
    assert html =~ "local"
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

  test "render_remote_post_content trims accidental leading breaks" do
    html = HtmlHelpers.render_remote_post_content("<br>First line<br>Second line", "wizard.casa")

    refute html =~ ~r/^<br\s*\/?>/
    assert html =~ "First line<br>Second line"
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

  test "make_content_safe_with_links links hyphenated fediverse handles" do
    html = HtmlHelpers.make_content_safe_with_links("Hello @lait-accompli@shitposter.world")

    assert html =~ ~s(href="/remote/lait-accompli@shitposter.world")
    assert html =~ ">@lait-accompli@shitposter.world</a>"
  end

  test "make_content_safe_with_links does not link unsafe http urls" do
    html = HtmlHelpers.make_content_safe_with_links("See https://user:pass@example.com/post")

    refute html =~ "<a "
    assert html =~ "https://user:pass@example.com/post"
  end

  test "make_content_safe_with_links escapes normalized href values" do
    html = HtmlHelpers.make_content_safe_with_links("See https://example.com/post?a=1&b=2")

    assert html =~ ~s(href="https://example.com/post?a=1&amp;b=2")
    assert html =~ "https://example.com/post?a=1&amp;b=2"
  end

  test "render_remote_post_content does not link unsafe plain text urls" do
    html =
      HtmlHelpers.render_remote_post_content(
        "<p>See https://user:pass@example.com/post</p>",
        "mastodon.social"
      )

    refute html =~ ~s(href="https://user:pass@example.com/post")
    assert html =~ "https://user:pass@example.com/post"
  end

  test "render_remote_post_content strips unsafe hrefs from sanitized remote anchors" do
    html =
      HtmlHelpers.render_remote_post_content(
        ~s(<p><a href="https://user:pass@example.com/post">remote</a></p>),
        "mastodon.social"
      )

    refute html =~ ~s(href="https://user:pass@example.com/post")
    assert html =~ ">remote</a>"
  end

  test "render_remote_post_content keeps safe remote and local hrefs" do
    html =
      HtmlHelpers.render_remote_post_content(
        ~s(<p><a href="https://example.com/post?a=1&amp;b=2">remote</a> <a href="/hashtag/elixir">local</a></p>),
        "mastodon.social"
      )

    assert html =~ ~s(href="https://example.com/post?a=1&amp;b=2")
    assert html =~ ~s(href="/hashtag/elixir")
  end

  test "render_remote_post_content strips unsafe image srcs from sanitized remote content" do
    html =
      HtmlHelpers.render_remote_post_content(
        ~s(<p><img src="https://user:pass@example.com/image.png" alt="bad"></p>),
        "mastodon.social"
      )

    refute html =~ ~s(src="https://user:pass@example.com/image.png")
    assert html =~ ~s(alt="bad")
  end

  test "safe_basic_html strips unsafe hrefs and srcs from sanitized HTML" do
    html =
      HtmlHelpers.safe_basic_html(
        ~s|<p>body</p><a href="javascript:alert(1)">bad</a><img src="javascript:alert(2)" alt="bad"><a href="https://example.com/safe">safe</a>|
      )

    assert html =~ "body"
    assert html =~ ~s(<a>bad</a>)
    assert html =~ ~s(<img alt="bad" />)
    assert html =~ ~s(href="https://example.com/safe")
    refute html =~ "javascript:"
  end

  test "ensure_https rejects unsafe URLs" do
    assert HtmlHelpers.ensure_https("http://example.com/image.png") ==
             "https://example.com/image.png"

    assert HtmlHelpers.ensure_https("https://example.com/image.png") ==
             "https://example.com/image.png"

    refute HtmlHelpers.ensure_https("javascript:alert(1)")
    refute HtmlHelpers.ensure_https("https://user:pass@example.com/image.png")
    refute HtmlHelpers.ensure_https("https://example.com/image.png\r\nLocation:https://evil.test")
    refute HtmlHelpers.ensure_https(nil)
  end

  test "safe_external_href rejects dangerous rendered links" do
    assert HtmlHelpers.safe_external_href("https://example.com/post?a=1&b=2") ==
             "https://example.com/post?a=1&b=2"

    refute HtmlHelpers.safe_external_href("javascript:alert(1)")
    refute HtmlHelpers.safe_external_href("https://user:pass@example.com/post")

    refute HtmlHelpers.safe_external_href(
             "https://example.com/post\r\nLocation:https://evil.test"
           )

    refute HtmlHelpers.safe_external_href(nil)
  end

  test "safe_external_image_url rejects unsafe auto-loaded image targets" do
    assert HtmlHelpers.safe_external_image_url("https://example.com/avatar.png") ==
             "https://example.com/avatar.png"

    assert HtmlHelpers.safe_external_image_url("http://example.com/avatar.webp?size=128") ==
             "http://example.com/avatar.webp?size=128"

    refute HtmlHelpers.safe_external_image_url("javascript:alert(1)")
    refute HtmlHelpers.safe_external_image_url("https://example.com/profile")
    refute HtmlHelpers.safe_external_image_url("https://user:pass@example.com/avatar.png")
    refute HtmlHelpers.safe_external_image_url("http://127.0.0.1/admin.png")

    refute HtmlHelpers.safe_external_image_url(
             "https://example.com/avatar.png\r\nLocation:https://evil.test"
           )

    refute HtmlHelpers.safe_external_image_url(nil)
  end

  test "safe_external_image_urls filters unsafe list entries" do
    assert HtmlHelpers.safe_external_image_urls([
             "https://example.com/one.jpg",
             "https://user:pass@example.com/two.jpg",
             "http://127.0.0.1/three.jpg",
             "https://example.com/four.avif"
           ]) == [
             "https://example.com/one.jpg",
             "https://example.com/four.avif"
           ]
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
