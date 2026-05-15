defmodule ElektrineSocialWeb.Components.Social.PostReactionsTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias ElektrineSocialWeb.Components.Social.PostReactions

  test "escapes remote reaction names before rendering custom emojis" do
    html =
      render_component(&PostReactions.post_reactions/1,
        post_id: 1,
        reactions: [
          %{
            emoji: ~s(<img src=x onerror="alert('xss')">),
            remote_count: 7,
            user_id: nil,
            user: nil,
            remote_actor: nil
          }
        ],
        current_user: %{id: 1}
      )

    refute html =~ ~s(<img src=x onerror="alert('xss')">)
    assert html =~ "&lt;img src=x onerror=&quot;alert(&#39;xss&#39;)&quot;&gt;"
  end
end
