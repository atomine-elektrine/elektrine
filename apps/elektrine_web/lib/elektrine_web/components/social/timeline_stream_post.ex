defmodule ElektrineWeb.Components.Social.TimelineStreamPost do
  @moduledoc """
  Stateful wrapper for a single timeline stream entry.

  Stream items stay responsible for ordering and insertion/removal, while this
  component receives targeted updates for interaction state so the card can
  patch in place without a stream reinsert.
  """

  use ElektrineWeb, :live_component

  import ElektrineWeb.Components.Social.ReplyItem, only: [reply_item: 1]
  import ElektrineWeb.Components.Social.TimelinePost, only: [timeline_post: 1]
  import ElektrineWeb.Components.User.UsernameEffects, only: [username_with_effects: 1]

  alias ElektrineWeb.Components.Social.PostUtilities

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :is_lemmy_post, PostUtilities.community_post?(assigns.post))

    ~H"""
    <div id={"timeline-stream-post-body-#{@post.id}"}>
      <%= if @first_recent_post_id && @post.id == @first_recent_post_id do %>
        <div class="divider text-xs font-semibold text-secondary/80">
          {if @recently_loaded_count > 0,
            do: "#{@recently_loaded_count} new posts",
            else: "New posts"}
        </div>
      <% end %>

      <%= if @is_lemmy_post do %>
        <.timeline_post
          post={@post}
          layout={:lemmy}
          current_user={@current_user}
          timezone={@timezone}
          time_format={@time_format}
          user_likes={@user_likes}
          user_downvotes={@user_downvotes}
          user_boosts={@user_boosts}
          user_saves={@user_saves}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          remote_follow_overrides={@remote_follow_overrides}
          user_statuses={@user_statuses}
          lemmy_counts={@lemmy_counts}
          post_interactions={@post_interactions}
          post_reactions_map={@post_reactions}
          reactions={Map.get(@post_reactions, @post.id, [])}
          replies={Map.get(@post_replies, @post.id, [])}
          resolve_reply_refs={true}
          show_ancestor_actions={true}
          on_image_click="open_image_modal"
          source="timeline"
        />
      <% else %>
        <.timeline_post
          post={@post}
          layout={:timeline}
          current_user={@current_user}
          timezone={@timezone}
          time_format={@time_format}
          user_likes={@user_likes}
          user_boosts={@user_boosts}
          user_saves={@user_saves}
          user_downvotes={@user_downvotes}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          remote_follow_overrides={@remote_follow_overrides}
          user_statuses={@user_statuses}
          lemmy_counts={@lemmy_counts}
          post_interactions={@post_interactions}
          post_reactions_map={@post_reactions}
          post_replies={@post_replies}
          reactions={Map.get(@post_reactions, @post.id, [])}
          resolve_reply_refs={true}
          show_ancestor_actions={true}
          on_image_click="open_image_modal"
          source="timeline"
        />

        <%= if @current_user && @reply_to_post && @reply_to_post.id == @post.id &&
              is_nil(@reply_to_reply_id) do %>
          <div
            id={"reply-form-#{@post.id}"}
            class="mt-3 p-4 bg-base-50 rounded-lg border border-base-200"
          >
            <div class="flex items-start gap-3">
              <div class="w-8 h-8 flex-shrink-0 overflow-visible">
                <.user_avatar user={@current_user} size="sm" user_statuses={@user_statuses} />
              </div>
              <div class="flex-1 min-w-0">
                <div class="text-sm opacity-70 mb-3">
                  {gettext("Replying to")}
                  <span class="font-medium text-error">
                    <%= if @reply_to_post.sender do %>
                      @{@reply_to_post.sender.handle ||
                        @reply_to_post.sender.username}@{Elektrine.Domains.default_user_handle_domain()}
                    <% else %>
                      <%= if Ecto.assoc_loaded?(@reply_to_post.remote_actor) && @reply_to_post.remote_actor do %>
                        @{@reply_to_post.remote_actor.username}@{@reply_to_post.remote_actor.domain}
                      <% else %>
                        a remote user
                      <% end %>
                    <% end %>
                  </span>
                </div>

                <%= if length(@reply_to_post_recent_replies) > 0 &&
                      Map.get(@post_replies, @post.id, []) == [] do %>
                  <div class="mb-3 border-l-2 border-cyan-500/60 pl-3 space-y-2">
                    <div class="text-xs font-semibold opacity-60 mb-2">Recent Replies:</div>
                    <%= for reply <- @reply_to_post_recent_replies do %>
                      <% has_sender = Map.get(reply, :sender) != nil

                      has_remote_actor =
                        case Map.get(reply, :remote_actor) do
                          nil -> false
                          %Ecto.Association.NotLoaded{} -> false
                          _actor -> true
                        end

                      has_author = Map.get(reply, :author) != nil
                      reply_content = Map.get(reply, :content) || ""
                      reply_preview = PostUtilities.plain_text_content(reply_content)

                      reply_preview =
                        if String.length(reply_preview) > 150 do
                          String.slice(reply_preview, 0, 150) <> "..."
                        else
                          reply_preview
                        end %>
                      <div class="text-sm">
                        <div class="flex items-center gap-2 mb-1">
                          <%= if has_sender do %>
                            <.username_with_effects
                              user={reply.sender}
                              display_name={false}
                              verified_size="xs"
                            />
                          <% else %>
                            <%= if has_remote_actor do %>
                              <span class="font-medium">
                                @{reply.remote_actor.username}@{reply.remote_actor.domain}
                              </span>
                            <% else %>
                              <%= if has_author do %>
                                <span class="font-medium">
                                  @{reply.author}{if reply.author_domain,
                                    do: "@#{reply.author_domain}"}
                                </span>
                              <% else %>
                                <span class="font-medium opacity-50">Remote user</span>
                              <% end %>
                            <% end %>
                          <% end %>
                          <span class="text-xs opacity-50">
                            ·
                            <.local_time
                              datetime={reply.inserted_at}
                              format="relative"
                              timezone={@timezone}
                              time_format={@time_format}
                            />
                          </span>
                        </div>
                        <div class="text-xs opacity-70 line-clamp-2">{reply_preview}</div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <ElektrineWeb.Components.Social.RemotePostShared.inline_reply_form
                  wrapper_class=""
                  content={@reply_content}
                  hidden_fields={[{"reply_to_id", @reply_to_post.id}]}
                  textarea_id={"reply-textarea-#{@reply_to_post.id}"}
                  placeholder={gettext("Post your reply...")}
                  textarea_class="textarea textarea-bordered w-full resize-y overflow-y-auto leading-tight"
                  textarea_style="min-height: 3rem; max-height: 15rem;"
                  rows={3}
                  on_submit="create_timeline_reply"
                  on_change="update_reply_content"
                  on_cancel="cancel_reply"
                  cancel_class="btn btn-ghost btn-sm"
                  submit_class="btn btn-secondary btn-sm"
                  submit_label={gettext("Reply")}
                  submit_icon="hero-paper-airplane"
                  submit_disable_with="Posting..."
                  form_class="space-y-3"
                  textarea_hook="AutoExpandTextarea"
                  textarea_mounted={JS.focus()}
                  textarea_update="ignore"
                  content_min={3}
                  counter_suffix={gettext(" required chars")}
                  show_counter={true}
                />
              </div>
            </div>
          </div>
        <% end %>

        <% replies = Map.get(@post_replies, @post.id, []) %>
        <%= if length(replies) > 0 do %>
          <div class="mt-3 pl-4 border-l-2 border-purple-500/60 space-y-3">
            <%= for reply <- replies do %>
              <% normalized = ElektrineWeb.Components.Social.ReplyItem.normalize_reply(reply)

              reply_target_id =
                Map.get(reply, :id) ||
                  Map.get(reply, :activitypub_id) ||
                  Map.get(reply, :ap_id) ||
                  normalized.ap_id %>
              <.reply_item
                reply={reply}
                post={@post}
                current_user={@current_user}
                user_statuses={@user_statuses}
                user_follows={@user_follows}
                pending_follows={@pending_follows}
                remote_follow_overrides={@remote_follow_overrides}
                user_likes={@user_likes}
                user_boosts={@user_boosts}
                timezone={@timezone}
                time_format={@time_format}
              />

              <%= if @current_user && @reply_to_reply_id == reply_target_id do %>
                <div class="mt-3 p-3 bg-base-200 rounded-lg border border-base-300">
                  <div class="flex items-start gap-2">
                    <div class="w-8 h-8 flex-shrink-0">
                      <.user_avatar user={@current_user} size="xs" />
                    </div>
                    <div class="flex-1 min-w-0">
                      <div class="text-xs opacity-70 mb-2">
                        Replying to
                        <span class="font-medium text-error">
                          @{normalized.handle}{if normalized.domain, do: "@#{normalized.domain}"}
                        </span>
                      </div>

                      <ElektrineWeb.Components.Social.RemotePostShared.inline_reply_form
                        wrapper_class=""
                        content={@reply_content}
                        hidden_fields={[{"reply_to_id", reply_target_id}]}
                        placeholder="Post your reply..."
                        textarea_class="textarea textarea-bordered textarea-sm w-full"
                        rows={2}
                        on_submit="create_timeline_reply"
                        on_change="update_reply_content"
                        on_cancel="cancel_reply"
                        cancel_class="btn btn-ghost btn-xs"
                        submit_class="btn btn-secondary btn-xs"
                        submit_label="Reply"
                        submit_icon="hero-paper-airplane"
                        submit_icon_class="w-3 h-3 mr-1"
                        submit_disable_with="Posting..."
                        form_class="space-y-2"
                        textarea_mounted={JS.focus()}
                        content_min={3}
                        counter_suffix={gettext(" required chars")}
                        show_counter={true}
                      />
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>

            <%= if @post.reply_count > length(replies) do %>
              <button
                phx-click="navigate_to_post"
                phx-value-id={@post.id}
                class="text-sm text-primary hover:underline font-medium"
                type="button"
              >
                View all {@post.reply_count} replies →
              </button>
            <% end %>
          </div>
        <% else %>
          <%= if (@post.reply_count || 0) > 0 do %>
            <div class="mt-3 pl-4 border-l-2 border-base-300">
              <%= if MapSet.member?(@loading_remote_replies, @post.id) do %>
                <div class="flex items-center gap-2 text-sm text-base-content/70">
                  <.spinner size="xs" />
                  <span>Loading replies...</span>
                </div>
              <% else %>
                <button
                  phx-click="load_remote_replies"
                  phx-value-post_id={@post.id}
                  phx-value-activitypub_id={@post.activitypub_id || ""}
                  class="text-sm text-primary hover:underline font-medium"
                  type="button"
                >
                  Load replies
                </button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end
end
