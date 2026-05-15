defmodule ElektrineSocialWeb.Components.Social.PostReactionsTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineSocialWeb.Components.Social.PostReactions

  test "escapes remote reaction names before rendering custom emojis" do
    quote = <<34>>
    raw_img = "<img src=x onerror=" <> quote <> "alert('xss')" <> quote <> ">"

    html =
      render_component(&PostReactions.post_reactions/1,
        post_id: 1,
        reactions: [
          %{
            emoji: raw_img,
            remote_count: 7,
            user_id: nil,
            user: nil,
            remote_actor: nil
          }
        ],
        current_user: %{id: 1}
      )

    escaped_quote = "&" <> "quot;"

    escaped_img =
      "&lt;img src=x onerror=" <>
        escaped_quote <>
        "alert" <>
        "(" <>
        "&#" <>
        "39;xss" <>
        "&#" <>
        "39;" <>
        ")" <>
        escaped_quote <>
        "&gt;"

    refute html =~ raw_img
    assert html =~ escaped_img
  end
end
