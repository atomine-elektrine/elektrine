defmodule ElektrineSocialWeb.RemotePostLive.ReplyAuthorComponents do
  @moduledoc false

  use ElektrineSocialWeb, :html

  import ElektrineSocialWeb.Components.User.HoverCard, only: [user_hover_card: 1]
  import ElektrineWeb.HtmlHelpers

  attr :layout, :atom, default: :inline
  attr :local_user, :map, default: nil
  attr :reply_actor, :map, default: nil
  attr :avatar_url, :string, default: nil
  attr :profile_path, :string, default: nil
  attr :display_name, :string, required: true
  attr :acct_label, :string, default: nil
  attr :published_label, :string, required: true
  attr :current_user, :map, default: nil
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}

  def reply_author_summary(assigns) do
    local_profile_path =
      if assigns.local_user do
        "/#{assigns.local_user.handle || assigns.local_user.username}"
      end

    assigns =
      assigns
      |> assign(:local_profile_path, local_profile_path)
      |> assign(:avatar_class, reply_author_avatar_class(assigns.layout))
      |> assign(:icon_class, reply_author_icon_class(assigns.layout))
      |> assign(:hover_class, reply_author_hover_class(assigns.layout))

    ~H"""
    <%= cond do %>
      <% @local_user -> %>
        <.user_hover_card
          user={@local_user}
          current_user={@current_user}
          user_follows={@user_follows}
          class={@hover_class}
        >
          <.link
            navigate={@local_profile_path}
            class="flex-shrink-0"
            aria-label={"Open #{@local_user.display_name || @local_user.username} profile"}
          >
            <%= if @local_user.avatar do %>
              <img
                src={Elektrine.Uploads.avatar_url(@local_user.avatar)}
                alt=""
                class={[@avatar_class, "rounded-full object-cover"]}
              />
            <% else %>
              <div
                class={[
                  @avatar_class,
                  "rounded-full text-primary-content flex items-center justify-center"
                ]}
                style="background: linear-gradient(135deg, var(--theme-avatar-accent-light-color), var(--theme-avatar-accent-color));"
              >
                <.icon name="hero-user" class={@icon_class} />
              </div>
            <% end %>
          </.link>
          <%= if @layout == :stacked do %>
            <div class="flex-1 min-w-0">
              <.link
                navigate={@local_profile_path}
                class="text-sm font-medium hover:text-error transition-colors"
              >
                {@local_user.display_name || @local_user.username}
              </.link>
              <%= if @current_user && @current_user.id == @local_user.id do %>
                <span class="text-xs text-info ml-1">(you)</span>
              <% end %>
              <div class="text-xs opacity-50">{@published_label}</div>
            </div>
          <% else %>
            <.link
              navigate={@local_profile_path}
              class="font-medium text-info hover:underline break-words"
            >
              {@local_user.display_name || @local_user.username}
            </.link>
            <%= if @current_user && @current_user.id == @local_user.id do %>
              <span class="text-info/70">(you)</span>
            <% end %>
          <% end %>
        </.user_hover_card>
        <.reply_author_inline_time :if={@layout == :inline} published_label={@published_label} />
      <% @reply_actor && @profile_path -> %>
        <.user_hover_card
          remote_actor={@reply_actor}
          current_user={@current_user}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          remote_follow_overrides={@remote_follow_overrides}
          class={@hover_class}
        >
          <.link
            navigate={@profile_path}
            class="flex-shrink-0"
            aria-label={"Open #{@display_name} profile"}
          >
            <%= if Elektrine.Strings.present?(@avatar_url) do %>
              <img src={@avatar_url} alt="" class={[@avatar_class, "rounded-full object-cover"]} />
            <% else %>
              <div class={[@avatar_class, "rounded-full bg-base-300 flex items-center justify-center"]}>
                <.icon name="hero-user" class={[@icon_class, "opacity-70"]} />
              </div>
            <% end %>
          </.link>
          <%= if @layout == :stacked do %>
            <div class="flex-1 min-w-0">
              <.link
                navigate={@profile_path}
                class="text-sm font-medium hover:text-primary transition-colors break-words"
              >
                {raw(
                  render_display_name_with_emojis(
                    @reply_actor.display_name || @reply_actor.username,
                    @reply_actor.domain
                  )
                )}
              </.link>
              <div class="text-xs opacity-50">
                <%= if Elektrine.Strings.present?(@acct_label) do %>
                  {@acct_label} ·
                <% end %>
                {@published_label}
              </div>
            </div>
          <% else %>
            <.link navigate={@profile_path} class="font-medium hover:underline break-words">
              {raw(
                render_display_name_with_emojis(
                  @reply_actor.display_name || @reply_actor.username,
                  @reply_actor.domain
                )
              )}
            </.link>
          <% end %>
        </.user_hover_card>
        <.reply_author_inline_time :if={@layout == :inline} published_label={@published_label} />
      <% true -> %>
        <%= if @profile_path do %>
          <.link
            navigate={@profile_path}
            class="pointer-events-auto relative z-20 flex-shrink-0"
            aria-label={"Open #{@display_name} profile"}
          >
            <.reply_author_avatar
              avatar_url={@avatar_url}
              avatar_class={@avatar_class}
              icon_class={@icon_class}
            />
          </.link>
        <% else %>
          <.reply_author_avatar
            avatar_url={@avatar_url}
            avatar_class={@avatar_class}
            icon_class={@icon_class}
          />
        <% end %>
        <%= if @layout == :stacked do %>
          <div class="flex-1 min-w-0">
            <%= if @profile_path do %>
              <.link
                navigate={@profile_path}
                class="pointer-events-auto relative z-20 text-sm font-medium hover:text-primary transition-colors break-words"
              >
                {@display_name}
              </.link>
            <% else %>
              <span class="text-sm font-medium break-words">{@display_name}</span>
            <% end %>
            <div class="text-xs opacity-50">
              <%= if Elektrine.Strings.present?(@acct_label) do %>
                {@acct_label} ·
              <% end %>
              {@published_label}
            </div>
          </div>
        <% else %>
          <%= if @profile_path do %>
            <.link
              navigate={@profile_path}
              class="pointer-events-auto relative z-20 font-medium hover:underline break-words"
            >
              {@display_name}
            </.link>
          <% else %>
            <span class="font-medium break-words">{@display_name}</span>
          <% end %>
          <.reply_author_inline_time published_label={@published_label} />
        <% end %>
    <% end %>
    """
  end

  attr :avatar_url, :string, default: nil
  attr :avatar_class, :string, required: true
  attr :icon_class, :string, required: true

  def reply_author_avatar(assigns) do
    ~H"""
    <%= if Elektrine.Strings.present?(@avatar_url) do %>
      <img
        src={@avatar_url}
        alt=""
        class={[@avatar_class, "rounded-full object-cover flex-shrink-0"]}
        aria-hidden="true"
      />
    <% else %>
      <div class={[
        @avatar_class,
        "rounded-full bg-base-300 flex items-center justify-center flex-shrink-0"
      ]}>
        <.icon name="hero-user" class={[@icon_class, "opacity-70"]} />
      </div>
    <% end %>
    """
  end

  attr :published_label, :string, required: true

  def reply_author_inline_time(assigns) do
    ~H"""
    <span class="text-base-content/40">·</span>
    <span class="text-base-content/50">{@published_label}</span>
    """
  end

  defp reply_author_hover_class(:stacked),
    do: "pointer-events-auto relative z-20 flex min-w-0 flex-1 items-start gap-2"

  defp reply_author_hover_class(_),
    do: "pointer-events-auto relative z-20 inline-flex min-w-0 items-center gap-2"

  defp reply_author_avatar_class(:stacked), do: "w-8 h-8"
  defp reply_author_avatar_class(_), do: "w-6 h-6"

  defp reply_author_icon_class(:stacked), do: "w-4 h-4"
  defp reply_author_icon_class(_), do: "w-3 h-3"
end
