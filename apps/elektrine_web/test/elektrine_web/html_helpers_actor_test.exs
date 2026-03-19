defmodule ElektrineWeb.HtmlHelpersActorTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.AccountsFixtures
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
  end
end
