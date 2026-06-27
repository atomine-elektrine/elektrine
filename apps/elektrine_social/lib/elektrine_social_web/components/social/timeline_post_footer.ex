defmodule ElektrineSocialWeb.Components.Social.TimelinePostFooter do
  @moduledoc false

  use Phoenix.Component

  import ElektrineWeb.CoreComponents
  import ElektrineSocialWeb.Components.Social.FollowButton, only: [local_follow_button: 1]
  import ElektrineSocialWeb.Components.Social.PostActions, only: [post_actions: 1]

  alias ElektrineSocialWeb.Components.Social.PostUtilities

  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :user_likes, :map, default: %{}
  attr :user_boosts, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :display_like_count, :integer, default: 0
  attr :display_boost_count, :integer, default: 0
  attr :display_comment_count, :integer, default: 0
  attr :show_follow_button, :boolean, default: true
  attr :show_view_button, :boolean, default: false
  attr :is_liked, :boolean, default: false
  attr :is_boosted, :boolean, default: false
  attr :is_saved, :boolean, default: false
  attr :on_comment, :string, default: "show_reply_form"
  attr :show_quote_button, :boolean, default: true
  attr :show_save_button, :boolean, default: true
  attr :action_post_id, :any, default: nil
  attr :action_value_name, :string, default: "message_id"
  attr :save_action_post_id, :any, default: nil
  attr :save_action_value_name, :string, default: nil
  attr :id_prefix, :string, default: "post"
  attr :counts_loading, :boolean, default: false

  def post_footer(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-y-2 gap-x-1 pt-2 border-t border-base-300">
      <div class="flex items-center gap-1 flex-shrink-0">
        <.post_actions
          post_id={@action_post_id || @post.id}
          current_user={@current_user}
          is_liked={@is_liked}
          is_boosted={@is_boosted}
          is_saved={@is_saved}
          like_count={@display_like_count}
          comment_count={@display_comment_count}
          boost_count={@display_boost_count}
          quote_count={@post.quote_count || 0}
          on_comment={@on_comment}
          show_quote={@show_quote_button}
          show_save={@show_save_button}
          value_name={@action_value_name}
          save_post_id={@save_action_post_id || @post.id}
          save_value_name={@save_action_value_name || "message_id"}
          dom_id_prefix={"#{@id_prefix}-actions-#{@post.id}"}
          size={:xs}
          counts_loading={@counts_loading}
        />

        <%= if @show_view_button do %>
          <%= if @post.federated && PostUtilities.safe_external_href(@post.activitypub_url) do %>
            <a
              href={PostUtilities.safe_external_href(@post.activitypub_url)}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-ghost btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm"
              title="Open on remote instance"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 sm:w-4 sm:h-4" />
            </a>
          <% else %>
            <.link
              navigate={Elektrine.Paths.post_path(@post)}
              class="btn btn-ghost btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm"
              title="View full post"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 sm:w-4 sm:h-4" />
            </.link>
          <% end %>
        <% end %>
      </div>

      <%= if @show_follow_button && @current_user do %>
        <.follow_actions
          post={@post}
          current_user={@current_user}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          remote_follow_overrides={@remote_follow_overrides}
          id_prefix={@id_prefix}
        />
      <% end %>
    </div>
    """
  end

  attr :post, :map, required: true
  attr :current_user, :map, required: true
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :id_prefix, :string, default: "post"

  defp follow_actions(assigns) do
    ~H"""
    <%= if @post.federated && @post.remote_actor do %>
      <% follow_state =
        remote_follow_button_state(
          @remote_follow_overrides,
          @user_follows,
          @pending_follows,
          @post.remote_actor.id
        )

      is_following = follow_state == "following"
      is_pending = follow_state == "pending" %>
      <div class="flex items-center gap-1">
        <button
          id={"#{@id_prefix}-remote-follow-#{@post.id}-#{@post.remote_actor.id}"}
          phx-click="toggle_follow_remote"
          phx-value-remote_actor_id={@post.remote_actor.id}
          phx-hook="RemoteFollowButton"
          data-remote-actor-id={@post.remote_actor.id}
          data-follow-state={follow_state}
          data-follow-variant="timeline"
          class={[
            "btn btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:opacity-70",
            cond do
              is_following ->
                "btn-ghost"

              is_pending ->
                "btn-ghost"

              true ->
                "btn-secondary phx-click-loading:bg-base-200 phx-click-loading:text-base-content"
            end
          ]}
          type="button"
        >
          <span class="inline-flex items-center">
            <span
              data-follow-display="following"
              class={if(follow_state != "following", do: "hidden")}
            >
              <span class="inline-flex items-center">
                <.icon name="hero-user-minus" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Unfollow
                </span>
              </span>
            </span>
            <span
              data-follow-display="pending"
              class={if(follow_state != "pending", do: "hidden")}
            >
              <span class="inline-flex items-center">
                <.icon name="hero-clock" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Requested
                </span>
              </span>
            </span>
            <span data-follow-display="none" class={if(follow_state != "none", do: "hidden")}>
              <span class="inline-flex items-center">
                <.icon name="hero-user-plus" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Follow
                </span>
              </span>
            </span>
          </span>
        </button>
      </div>
    <% end %>

    <%= if !@post.federated && @post.sender && @post.sender.id != @current_user.id do %>
      <div class="flex items-center gap-1">
        <.local_follow_button user_id={@post.sender.id} user_follows={@user_follows} />
      </div>
    <% end %>
    """
  end

  defp remote_follow_button_state(
         remote_follow_overrides,
         user_follows,
         pending_follows,
         remote_actor_id
       ) do
    case remote_follow_override_state(remote_follow_overrides, remote_actor_id) do
      state when state in ["following", "pending", "none"] ->
        state

      _ ->
        cond do
          Map.get(user_follows, {:remote, remote_actor_id}, false) ||
              Map.get(user_follows, remote_actor_id, false) ->
            "following"

          Map.get(pending_follows, {:remote, remote_actor_id}, false) ||
              Map.get(pending_follows, remote_actor_id, false) ->
            "pending"

          true ->
            "none"
        end
    end
  end

  defp remote_follow_override_state(remote_follow_overrides, remote_actor_id)
       when is_map(remote_follow_overrides) do
    case Map.get(remote_follow_overrides, remote_actor_id) ||
           Map.get(remote_follow_overrides, {:remote, remote_actor_id}) do
      state when is_atom(state) -> Atom.to_string(state)
      state -> state
    end
  end

  defp remote_follow_override_state(_, _), do: nil
end
