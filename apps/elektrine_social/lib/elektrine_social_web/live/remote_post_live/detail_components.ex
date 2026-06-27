defmodule ElektrineSocialWeb.RemotePostLive.DetailComponents do
  @moduledoc false

  use ElektrineSocialWeb, :html

  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineSocialWeb.RemotePostLive.DetailState

  import ElektrineSocialWeb.Components.Social.TimelinePost, only: [timeline_post: 1]

  attr :message, :map, required: true
  attr :replies, :list, default: []
  attr :post_interactions, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :post_reactions, :map, default: %{}
  attr :current_user, :map, default: nil
  attr :replies_loaded, :boolean, default: false
  attr :remote_poll_vote, :map, default: nil
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :lemmy_counts, :map, default: %{}
  attr :counts_loading, :boolean, default: false

  def standard_timeline_detail_post(assigns) do
    message =
      DetailState.detail_message_with_reply_count(
        assigns.message,
        assigns.replies,
        assigns.replies_loaded
      )

    interaction_state = DetailState.detail_message_interaction(assigns.post_interactions, message)
    is_community_post = PostUtilities.community_post?(message)

    assigns =
      assigns
      |> assign(:message, message)
      |> assign(:interaction_state, interaction_state)
      |> assign(:reactions, DetailState.detail_message_reactions(assigns.post_reactions, message))
      |> assign(:saved?, DetailState.detail_message_saved?(assigns.user_saves, message))
      |> assign(
        :detail_user_saves,
        DetailState.detail_message_save_map(assigns.user_saves, message)
      )
      |> assign(:is_community_post, is_community_post)

    message =
      if interaction_state.boosted && (message.share_count || 0) < 1 do
        %{message | share_count: 1}
      else
        message
      end

    assigns = assign(assigns, :message, message)

    ~H"""
    <.timeline_post
      post={@message}
      current_user={@current_user}
      layout={if @is_community_post, do: :lemmy, else: :timeline}
      interaction_mode={if @is_community_post, do: :vote, else: :like_only}
      remote_poll_vote={@remote_poll_vote}
      lemmy_counts={@lemmy_counts || %{}}
      replies={@replies}
      user_likes={%{@message.id => @interaction_state.liked}}
      user_boosts={%{@message.id => @interaction_state.boosted}}
      user_downvotes={%{@message.id => Map.get(@interaction_state, :vote) == "down"}}
      user_saves={@detail_user_saves}
      post_interactions={@post_interactions}
      post_reactions_map={@post_reactions}
      user_follows={@user_follows}
      pending_follows={@pending_follows}
      remote_follow_overrides={@remote_follow_overrides}
      reactions={@reactions}
      clickable={false}
      source="timeline"
      id_prefix="remote-post-detail"
      show_follow_button={false}
      show_admin_actions={false}
      show_post_dropdown={false}
      on_like={if @is_community_post, do: "upvote_post", else: "like_post"}
      on_unlike={if @is_community_post, do: "unupvote_post", else: "unlike_post"}
      on_downvote="downvote_post"
      on_undownvote="undownvote_post"
      on_comment={if @is_community_post, do: "show_reply_form", else: "toggle_reply_form"}
      show_quote_button={false}
      action_post_id={@message.id}
      action_value_name="message_id"
      save_action_post_id={@message.id}
      save_action_value_name="message_id"
      saved_override={@saved?}
      counts_loading={@counts_loading}
    />
    """
  end

  attr :replies_loading, :boolean, default: false
  attr :replies_loaded, :boolean, default: false
  attr :hydration_state, :string, default: "idle"
  attr :reported_reply_count, :integer, default: 0
  attr :loaded_reply_count, :integer, default: 0
  attr :empty_message, :string, default: "No comments yet"
  attr :load_label, :string, default: "Load Comments"

  def empty_comments_state(assigns) do
    ~H"""
    <div
      class="card panel-card rounded-lg p-4 min-h-[14rem]"
      data-comments-state="idle"
    >
      <div class="flex min-h-[12rem] flex-col items-center justify-center text-center text-base-content/60">
        <.icon name="hero-chat-bubble-left" class="w-12 h-12 mb-3 opacity-30" />
        <%= cond do %>
          <% @replies_loading && !@replies_loaded -> %>
            <div class="flex flex-col items-center gap-3" data-comments-loading-placeholder>
              <.spinner size="md" />
              <p>Loading comments...</p>
            </div>
          <% @hydration_state in ["syncing", "partial"] and @reported_reply_count > 0 -> %>
            <div class="space-y-2">
              <p>
                <%= if @loaded_reply_count > 0 do %>
                  Showing {@loaded_reply_count} of {@reported_reply_count} comments cached locally.
                <% else %>
                  Importing comments from the remote thread...
                <% end %>
              </p>
              <button type="button" phx-click="refresh_comments" class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh comments
              </button>
            </div>
          <% @hydration_state == "failed" and @reported_reply_count > 0 -> %>
            <div class="space-y-2">
              <p>
                Couldn&apos;t import comments yet. They may still be available on the original server.
              </p>
              <button type="button" phx-click="refresh_comments" class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry sync
              </button>
            </div>
          <% @replies_loaded -> %>
            <p>{@empty_message}</p>
          <% true -> %>
            <button type="button" phx-click="load_comments" class="btn btn-primary btn-sm">
              <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> {@load_label}
            </button>
        <% end %>
      </div>
    </div>
    """
  end
end
