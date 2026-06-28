defmodule ElektrineWeb.Components.User.HoverCardTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo
  alias ElektrineSocialWeb.Components.User.HoverCard

  test "renders custom emojis in local hover card bios" do
    Repo.insert!(
      CustomEmoji.changeset(%CustomEmoji{}, %{
        shortcode: "blobcat",
        image_url: "https://example.com/blobcat.png",
        visible_in_picker: false,
        disabled: false
      })
    )

    user = %{
      id: 123,
      username: "alice",
      handle: "alice",
      inserted_at: ~N[2024-01-01 00:00:00],
      verified: false,
      profile: %{
        display_name: "Alice",
        description: "bio :blobcat:",
        following_count: 1,
        followers_count: 2,
        username_effect: nil,
        username_animation_speed: nil,
        username_glow_color: nil,
        username_glow_intensity: nil,
        username_shadow_color: nil,
        username_gradient_from: nil,
        username_gradient_to: nil,
        tick_color: nil
      }
    }

    html =
      render_component(&HoverCard.user_hover_card/1,
        user: user,
        current_user: nil,
        inner_block: [
          %{
            inner_block: fn _, _ ->
              "@alice"
            end
          }
        ]
      )

    assert html =~ "bio"
    assert html =~ "custom-emoji"
    assert html =~ "blobcat.png"
  end

  test "keeps full-width layout classes off the hover trigger" do
    user = %{
      id: 124,
      username: "bob",
      handle: "bob",
      inserted_at: ~N[2024-01-01 00:00:00],
      verified: false,
      profile: %{
        display_name: "Bob",
        description: nil,
        following_count: 0,
        followers_count: 0,
        username_effect: nil,
        username_animation_speed: nil,
        username_glow_color: nil,
        username_glow_intensity: nil,
        username_shadow_color: nil,
        username_gradient_from: nil,
        username_gradient_to: nil,
        tick_color: nil
      }
    }

    html =
      render_component(&HoverCard.user_hover_card/1,
        user: user,
        current_user: nil,
        class: "!flex min-w-0 flex-1 items-center gap-3",
        trigger_class: "inline-flex max-w-full min-w-0 items-center gap-3",
        inner_block: [
          %{
            inner_block: fn _, _ ->
              "@bob"
            end
          }
        ]
      )

    document = Floki.parse_fragment!(html)

    wrapper_class =
      document |> Floki.find(~s([phx-hook="UserHoverCard"])) |> Floki.attribute("class")

    trigger_class = document |> Floki.find("[data-hover-trigger]") |> Floki.attribute("class")

    assert Enum.any?(wrapper_class, &String.contains?(&1, "flex-1"))
    assert Enum.any?(trigger_class, &String.contains?(&1, "inline-flex"))
    refute Enum.any?(trigger_class, &String.contains?(&1, "flex-1"))
  end
end
