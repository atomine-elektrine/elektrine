defmodule ElektrineWeb.HtmlHelpersActorTest do
  use Elektrine.DataCase, async: true

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
      display_name: "https://elektrine.com/remote/zero@strelizia.net",
      username: "zero",
      domain: "strelizia.net"
    }

    assert HtmlHelpers.actor_display_name_text(actor) == "zero"
    assert HtmlHelpers.render_actor_display_name(actor) == "zero"
  end
end
