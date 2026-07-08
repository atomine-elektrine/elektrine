defmodule ElektrineSocialWeb.RemotePostLive.AncestorContextComponents do
  @moduledoc false

  use ElektrineSocialWeb, :html

  alias Elektrine.AccountIdentifiers
  alias Elektrine.Paths
  alias ElektrineSocialWeb.RemotePostLive.SurfaceHelpers
  alias ElektrineWeb.UrlHelpers

  import ElektrineWeb.HtmlHelpers,
    only: [render_remote_post_content: 2, safe_external_image_url: 1]

  attr :in_reply_to, :string, default: nil
  attr :reply_parent, :map, default: nil
  attr :reply_parent_actor, :map, default: nil
  attr :reply_ancestors, :list, default: []
  attr :post_interactions, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :post_reactions, :map, default: %{}
  attr :current_user, :map, default: nil
  attr :replying_to_comment_id, :any, default: nil
  attr :comment_reply_content, :string, default: ""

  def ancestor_context_stack(assigns) do
    ~H"""
    <%= if @in_reply_to do %>
      <% fallback_entry =
        if is_map(@reply_parent) do
          [
            %{
              post: @reply_parent,
              actor: @reply_parent_actor,
              in_reply_to: @in_reply_to
            }
          ]
        else
          []
        end

      ancestors_for_render =
        if Enum.empty?(@reply_ancestors),
          do: fallback_entry,
          else: @reply_ancestors

      ancestors_for_render = Enum.reverse(ancestors_for_render)
      ancestor_count = length(ancestors_for_render) %>
      <%= if ancestors_for_render != [] do %>
        <section class="mb-4 space-y-2" aria-label="Conversation context">
          <div class="flex items-center gap-2 text-[11px] uppercase tracking-[0.18em] text-base-content/45">
            <span>Replying to</span>
            <span class="opacity-60 normal-case tracking-normal">
              {ancestor_count} earlier {if ancestor_count == 1, do: "post", else: "posts"}
            </span>
          </div>

          <%= for {ancestor, idx} <- Enum.with_index(ancestors_for_render) do %>
            <% parent_post = ancestor.post
            parent_actor = ancestor.actor

            parent_ref = ancestor_post_ref(parent_post, ancestor.in_reply_to)

            parent_author = reply_parent_author_label(parent_post, parent_actor)

            parent_domain =
              reply_parent_content_domain(parent_post, parent_actor, parent_ref)

            parent_title =
              if is_map(parent_post), do: parent_post["name"], else: nil

            parent_content =
              if is_map(parent_post), do: parent_post["content"], else: nil

            local_parent_id = SurfaceHelpers.ancestor_local_message_id(parent_post)
            has_external_link = http_url?(parent_ref)

            parent_target =
              cond do
                is_integer(local_parent_id) -> Paths.post_path(local_parent_id)
                has_external_link -> Paths.post_path(parent_ref)
                true -> nil
              end %>
            <div
              class={[
                "card panel-card rounded-lg px-3 py-2.5 transition-colors hover:bg-base-200/60",
                parent_target && "cursor-pointer"
              ]}
              phx-click={parent_target && Phoenix.LiveView.JS.navigate(parent_target)}
            >
              <article>
                <div class="flex items-start gap-2 min-w-0">
                  <% parent_avatar_url =
                    if parent_actor, do: safe_external_image_url(parent_actor.avatar_url) %>
                  <%= if parent_avatar_url do %>
                    <img
                      src={parent_avatar_url}
                      alt=""
                      class="w-7 h-7 rounded-full object-cover flex-shrink-0 mt-0.5"
                    />
                  <% else %>
                    <div class="w-7 h-7 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0 mt-0.5">
                      <.icon name="hero-user" class="w-4 h-4 opacity-60" />
                    </div>
                  <% end %>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs min-w-0">
                      <span class="font-medium break-words">{parent_author}</span>
                      <%= if parent_domain do %>
                        <span class="break-words text-base-content/55">on {parent_domain}</span>
                      <% end %>
                      <%= if parent_target do %>
                        <span class="ml-auto inline-flex items-center gap-1 text-[11px] font-medium text-primary">
                          Open parent <.icon name="hero-arrow-right" class="w-3 h-3" />
                        </span>
                      <% end %>
                    </div>
                  </div>
                </div>
                <%= if Elektrine.Strings.present?(parent_title) do %>
                  <div class="mt-2 text-sm font-semibold line-clamp-1 break-words">
                    {parent_title}
                  </div>
                <% end %>
                <%= if Elektrine.Strings.present?(parent_content) do %>
                  <div class="mt-1 text-sm opacity-75 line-clamp-2 break-words post-content">
                    {raw(render_remote_post_content(parent_content, parent_domain))}
                  </div>
                <% end %>
              </article>
            </div>
          <% end %>
        </section>
      <% end %>
    <% end %>
    """
  end

  defp ancestor_post_ref(parent_post, in_reply_to_ref) do
    [
      map_get_value(parent_post, "id"),
      in_reply_to_ref,
      map_get_value(parent_post, "url")
    ]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

  defp reply_parent_author_label(reply_parent, reply_parent_actor) do
    cond do
      reply_parent_actor && is_binary(reply_parent_actor.username) &&
          is_binary(reply_parent_actor.domain) ->
        "@#{reply_parent_actor.username}@#{reply_parent_actor.domain}"

      is_map(reply_parent) && is_map(reply_parent["_local_user"]) ->
        local_user = reply_parent["_local_user"]

        AccountIdentifiers.at_local_handle(local_user)

      is_map(reply_parent) && is_binary(reply_parent["_fallback_author"]) ->
        reply_parent["_fallback_author"]

      is_map(reply_parent) && is_binary(reply_parent["attributedTo"]) ->
        "@#{SurfaceHelpers.extract_username_from_uri(reply_parent["attributedTo"])}"

      true ->
        "original post"
    end
  end

  defp reply_parent_content_domain(reply_parent, reply_parent_actor, in_reply_to) do
    cond do
      reply_parent_actor && is_binary(reply_parent_actor.domain) ->
        reply_parent_actor.domain

      is_map(reply_parent) && is_binary(reply_parent["attributedTo"]) ->
        UrlHelpers.host_from_url(reply_parent["attributedTo"])

      is_binary(in_reply_to) ->
        UrlHelpers.host_from_url(in_reply_to)

      true ->
        nil
    end
  end

  defp http_url?(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.starts_with?(["http://", "https://"])
  end

  defp http_url?(_), do: false

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, remote_post_atom_key(key))
    end
  end

  defp map_get_value(_, _), do: nil

  defp remote_post_atom_key("id"), do: :id
  defp remote_post_atom_key("url"), do: :url
  defp remote_post_atom_key(_), do: nil
end
