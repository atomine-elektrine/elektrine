defmodule ElektrineSocialWeb.Components.Social.PostReactions do
  @moduledoc """
  Reusable emoji reactions component for posts.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers, only: [render_custom_emojis: 2]

  @default_emojis ["👍", "❤️", "😂", "🔥", "😮", "😢"]

  @doc """
  Renders emoji reactions with a quick picker dropdown.
  """
  attr :post_id, :any, required: true
  attr :reactions, :list, default: []
  attr :current_user, :map, default: nil
  attr :on_react, :string, default: "react_to_post"
  attr :size, :atom, default: :xs
  attr :value_name, :string, default: "post_id"
  attr :actor_uri, :string, default: nil
  attr :show_picker, :boolean, default: true
  attr :emojis, :list, default: @default_emojis

  def post_reactions(assigns) do
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil

    grouped_reactions = Enum.group_by(assigns.reactions, & &1.emoji)

    formatted_reactions =
      grouped_reactions
      |> Enum.map(fn {emoji, reactions} ->
        user_reacted = Enum.any?(reactions, &(&1.user_id == current_user_id))

        usernames =
          reactions
          |> Enum.map(fn reaction ->
            cond do
              reaction.user && reaction.user.username ->
                reaction.user.username

              reaction.remote_actor && reaction.remote_actor.username ->
                "#{reaction.remote_actor.username}@#{reaction.remote_actor.domain}"

              true ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(10)

        %{
          emoji: emoji,
          count: length(reactions),
          user_reacted: user_reacted,
          usernames: usernames,
          instance_domain: reaction_instance_domain(reactions, assigns.actor_uri)
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)

    {btn_class, text_class, picker_btn_class, picker_icon_class} = size_classes(assigns.size)

    assigns =
      assigns
      |> assign(:formatted_reactions, formatted_reactions)
      |> assign(:btn_class, btn_class)
      |> assign(:text_class, text_class)
      |> assign(:picker_btn_class, picker_btn_class)
      |> assign(:picker_icon_class, picker_icon_class)
      |> assign(
        :reaction_value_attrs,
        build_reaction_value_attrs(assigns.value_name, assigns.post_id, assigns.actor_uri)
      )

    ~H"""
    <%= if length(@formatted_reactions) > 0 || (@current_user && @show_picker) do %>
      <div class="flex flex-wrap items-center gap-1.5">
        <%= for reaction <- @formatted_reactions do %>
          <% tooltip = Enum.join(reaction.usernames, ", ") %>
          <% tooltip =
            if reaction.count > 10, do: tooltip <> " and #{reaction.count - 10} more", else: tooltip %>
          <button
            phx-click={@on_react}
            {@reaction_value_attrs}
            phx-value-emoji={reaction.emoji}
            class={[
              @btn_class,
              "tooltip tooltip-top",
              if(reaction.user_reacted, do: "btn-secondary", else: "btn-ghost")
            ]}
            type="button"
            data-tip={tooltip}
          >
            <span>{raw(render_custom_emojis(reaction.emoji, reaction.instance_domain))}</span>
            <span class={@text_class}>{reaction.count}</span>
          </button>
        <% end %>

        <%= if @current_user && @show_picker do %>
          <div class="dropdown dropdown-top">
            <button
              type="button"
              tabindex="0"
              class={@picker_btn_class}
              title="Add reaction"
              onclick="event.stopPropagation(); this.focus();"
            >
              <.icon name="hero-face-smile" class={@picker_icon_class} />
            </button>
            <div tabindex="0" class="dropdown-content z-30 menu p-2 rounded-box">
              <div class="flex gap-1">
                <%= for emoji <- @emojis do %>
                  <button
                    phx-click={@on_react}
                    {@reaction_value_attrs}
                    phx-value-emoji={emoji}
                    class="btn btn-ghost btn-sm text-lg"
                    type="button"
                  >
                    {emoji}
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp size_classes(:xs) do
    {
      "btn btn-xs sm:btn-sm gap-1 min-w-0",
      "text-xs sm:text-sm",
      "btn btn-ghost btn-xs sm:btn-sm",
      "w-3.5 h-3.5 sm:w-4 sm:h-4"
    }
  end

  defp size_classes(:sm) do
    {
      "btn btn-sm gap-1 min-w-0",
      "text-sm",
      "btn btn-ghost btn-sm",
      "w-4 h-4"
    }
  end

  defp size_classes(_size), do: size_classes(:xs)

  defp build_reaction_value_attrs(value_name, post_id, actor_uri) do
    [{"phx-value-#{value_name}", post_id}] ++ actor_uri_attr(actor_uri)
  end

  defp actor_uri_attr(actor_uri) when is_binary(actor_uri) do
    case String.trim(actor_uri) do
      "" -> []
      trimmed -> [{"phx-value-actor_uri", trimmed}]
    end
  end

  defp actor_uri_attr(_), do: []

  defp reaction_instance_domain(reactions, actor_uri) when is_list(reactions) do
    Enum.find_value(reactions, actor_uri_domain(actor_uri), fn reaction ->
      cond do
        reaction.remote_actor && is_binary(reaction.remote_actor.domain) &&
            reaction.remote_actor.domain != "" ->
          reaction.remote_actor.domain

        is_binary(actor_uri_domain(actor_uri)) ->
          actor_uri_domain(actor_uri)

        true ->
          nil
      end
    end)
  end

  defp reaction_instance_domain(_, actor_uri), do: actor_uri_domain(actor_uri)

  defp actor_uri_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp actor_uri_domain(_), do: nil
end
