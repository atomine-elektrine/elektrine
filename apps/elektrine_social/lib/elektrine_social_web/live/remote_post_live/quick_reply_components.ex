defmodule ElektrineSocialWeb.RemotePostLive.QuickReplyComponents do
  @moduledoc false

  use ElektrineSocialWeb, :html

  alias Elektrine.AccountIdentifiers
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Paths
  alias ElektrineSocialWeb.RemotePostLive.SurfaceHelpers
  alias ElektrineWeb.UrlHelpers

  import ElektrineWeb.HtmlHelpers,
    only: [render_remote_post_content: 3, safe_external_image_url: 1]

  attr :replies, :list, required: true
  attr :reply_content_domain, :any, default: nil
  attr :id_prefix, :string, default: "remote-post-quick-reply-"

  def quick_reply_recent_replies_preview(assigns) do
    ~H"""
    <%= if length(@replies) > 0 do %>
      <div class="timeline-thread-preview-list timeline-thread-preview-list--flush space-y-2 text-left">
        <div class="text-xs font-semibold opacity-60">Recent Replies:</div>
        <%= for reply <- @replies do %>
          <% reply_view = quick_reply_preview_view(assigns, reply) %>
          <% author_preview = reply_view.author %>
          <% reply_click = reply_view.click %>
          <div
            class={[
              "timeline-thread-preview-item relative timeline-thread-comment-card timeline-thread-preview-item--flush text-left text-sm rounded-lg border border-base-300/70 px-3 py-2 transition-all duration-150",
              reply_click &&
                "cursor-pointer hover:border-base-content/20"
            ]}
            id={reply_view.dom_id}
            phx-hook={reply_click && "PostClick"}
            data-click-event={reply_click && reply_click.event}
            data-id={reply_click && reply_click.id}
            data-post-id={reply_click && reply_click.post_id}
          >
            <%= if reply_click do %>
              <.link
                navigate={Paths.post_path(reply_click.id || reply_click.post_id)}
                class="hidden"
                data-post-nav-link
                tabindex="-1"
                aria-hidden="true"
              >
                Open reply
              </.link>
            <% end %>
            <div class="flex items-center gap-2 mb-1 min-w-0">
              <%= if author_preview.profile_path do %>
                <.link navigate={author_preview.profile_path} class="w-5 h-5 flex-shrink-0">
                  <%= if author_avatar_url = safe_external_image_url(author_preview.avatar_url) do %>
                    <img
                      src={author_avatar_url}
                      alt=""
                      class="w-5 h-5 rounded-full object-cover"
                    />
                  <% else %>
                    <div class="w-5 h-5 rounded-full bg-base-300 flex items-center justify-center">
                      <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                    </div>
                  <% end %>
                </.link>
                <.link
                  navigate={author_preview.profile_path}
                  class="font-medium truncate hover:underline"
                >
                  {author_preview.label}
                </.link>
              <% else %>
                <%= if author_avatar_url = safe_external_image_url(author_preview.avatar_url) do %>
                  <img
                    src={author_avatar_url}
                    alt=""
                    class="w-5 h-5 rounded-full object-cover flex-shrink-0"
                  />
                <% else %>
                  <div class="w-5 h-5 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                  </div>
                <% end %>
                <span class="font-medium truncate">{author_preview.label}</span>
              <% end %>
              <%= if reply_view.published_label do %>
                <span class="text-xs opacity-50">
                  · {reply_view.published_label}
                </span>
              <% end %>
            </div>
            <div class="text-xs opacity-75 line-clamp-2 break-words">
              {raw(reply_view.content_html)}
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp quick_reply_preview_view(assigns, reply) when is_map(reply) do
    published = map_get_value(reply, "published")
    content = map_get_value(reply, "content") || ""

    id_ref =
      map_get_value(reply, "id") || map_get_value(reply, "_local_activitypub_id") || "unknown"

    render_domain = reply_render_domain(reply, nil, Map.get(assigns, :reply_content_domain))
    mention_hints = reply_mention_domain_hints(reply)

    %{
      author: quick_reply_author_preview(reply),
      click: quick_reply_click_target(reply),
      dom_id:
        Map.get(assigns, :id_prefix, "remote-post-quick-reply-") <> URI.encode_www_form(id_ref),
      published_label: if(published, do: APHelpers.format_activitypub_date(published)),
      content_html: render_remote_post_content(content, render_domain, mention_hints)
    }
  end

  defp quick_reply_preview_view(assigns, _),
    do: quick_reply_preview_view(assigns, %{})

  attr :show_reply_form, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :quick_reply_recent_replies, :list, default: []
  attr :reply_content, :string, default: ""
  attr :reply_content_domain, :any, default: nil
  attr :replying_to_comment_id, :any, default: nil
  attr :show_recent_replies_preview, :boolean, default: true

  def standard_timeline_detail_reply_box(assigns) do
    ~H"""
    <%= if @show_reply_form && @current_user && is_nil(@replying_to_comment_id) do %>
      <div class="timeline-thread-comment-card rounded-lg border border-base-300/70 bg-base-100 p-3 mb-4">
        <div class="space-y-3">
          <.quick_reply_recent_replies_preview
            :if={@show_recent_replies_preview}
            replies={@quick_reply_recent_replies}
            reply_content_domain={@reply_content_domain}
            id_prefix="remote-post-inline-component-reply-"
          />

          <ElektrineSocialWeb.Components.Social.RemotePostShared.inline_reply_form
            wrapper_class=""
            content={@reply_content}
            textarea_id="remote-post-reply-textarea"
            textarea_class="textarea textarea-bordered w-full"
            rows={4}
            form_class="space-y-3"
            on_submit="submit_reply"
            on_change="update_reply_content"
            on_cancel="toggle_reply_form"
            cancel_class="btn btn-ghost btn-sm"
            submit_class="btn btn-secondary btn-sm"
            textarea_debounce="300"
            textarea_hook="AutoExpandTextarea"
            submit_label="Reply"
            submit_icon="hero-paper-airplane"
            submit_icon_class="w-4 h-4 mr-1"
            submit_disable_with="Posting..."
            content_min={3}
            counter_suffix={gettext(" required chars")}
            show_counter={true}
          />
        </div>
      </div>
    <% end %>

    <%= if !@current_user do %>
      <div class="card panel-card rounded-lg p-4 mb-6 text-center">
        <.link navigate={Paths.login_path()} class="btn btn-secondary btn-sm">
          Sign in to interact
        </.link>
      </div>
    <% end %>
    """
  end

  defp quick_reply_author_preview(reply) when is_map(reply) do
    local_user = map_get_value(reply, "_local_user")

    if is_map(local_user) do
      username = Map.get(local_user, :username) || Map.get(local_user, "username")
      handle = Map.get(local_user, :handle) || Map.get(local_user, "handle") || username
      avatar = Map.get(local_user, :avatar) || Map.get(local_user, "avatar")

      avatar_url =
        if Elektrine.Strings.present?(avatar) do
          Elektrine.Uploads.avatar_url(avatar)
        else
          nil
        end

      %{
        label: AccountIdentifiers.at_local_handle(handle),
        avatar_url: avatar_url,
        profile_path: if(is_binary(handle) && handle != "", do: "/#{handle}", else: nil)
      }
    else
      author_uri =
        map_get_value(reply, "attributedTo") || map_get_value(reply, "actor")

      fallback = SurfaceHelpers.build_reply_author_fallback(reply, author_uri)

      label =
        cond do
          Elektrine.Strings.present?(fallback.acct_label) ->
            fallback.acct_label

          Elektrine.Strings.present?(author_uri) ->
            "@#{SurfaceHelpers.extract_username_from_uri(author_uri)}"

          true ->
            "Remote user"
        end

      %{
        label: label,
        avatar_url: fallback.avatar_url,
        profile_path: fallback.profile_path
      }
    end
  end

  defp quick_reply_click_target(reply) when is_map(reply) do
    local_activitypub_id = map_get_value(reply, "_local_activitypub_id")
    activitypub_id = map_get_value(reply, "id")

    cond do
      is_binary(local_activitypub_id) && local_activitypub_id != "" ->
        %{event: "navigate_to_remote_post", id: nil, post_id: local_activitypub_id}

      is_binary(activitypub_id) && activitypub_id != "" ->
        %{event: "navigate_to_remote_post", id: nil, post_id: activitypub_id}

      true ->
        nil
    end
  end

  defp reply_render_domain(reply, reply_actor, fallback_domain) do
    cond do
      is_map(reply_actor) && is_binary(reply_actor.domain) && reply_actor.domain != "" ->
        reply_actor.domain

      host = host_from_reply_actor_ref(reply) ->
        host

      is_binary(fallback_domain) && fallback_domain != "" ->
        fallback_domain

      true ->
        nil
    end
  end

  defp reply_mention_domain_hints(reply) do
    reply
    |> field_value(["inReplyToAuthor", "in_reply_to_author"])
    |> short_mention_domain_hints()
  end

  defp host_from_reply_actor_ref(reply) do
    reply
    |> field_value(["attributedTo", "actor"])
    |> UrlHelpers.host_from_url()
  end

  defp short_mention_domain_hints(author) when is_binary(author) do
    case Regex.run(
           ~r/^@([a-zA-Z0-9_][a-zA-Z0-9_-]*)@([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])$/,
           String.trim(author)
         ) do
      [_, username, domain] -> %{String.downcase(username) => domain}
      _ -> %{}
    end
  end

  defp short_mention_domain_hints(_), do: %{}

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> field_value(value, key) end)
  end

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key) when is_binary(key), do: map_get_value(value, key)
  defp field_value(%{} = value, key), do: Map.get(value, key)
  defp field_value(_, _), do: nil

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, remote_post_atom_key(key))
    end
  end

  defp map_get_value(_, _), do: nil

  defp remote_post_atom_key("id"), do: :id
  defp remote_post_atom_key("_local_activitypub_id"), do: :_local_activitypub_id
  defp remote_post_atom_key("_local_user"), do: :_local_user
  defp remote_post_atom_key("attributedTo"), do: :attributedTo
  defp remote_post_atom_key("actor"), do: :actor
  defp remote_post_atom_key("content"), do: :content
  defp remote_post_atom_key("published"), do: :published
  defp remote_post_atom_key("inReplyToAuthor"), do: :inReplyToAuthor
  defp remote_post_atom_key("in_reply_to_author"), do: :in_reply_to_author
  defp remote_post_atom_key(_), do: nil
end
