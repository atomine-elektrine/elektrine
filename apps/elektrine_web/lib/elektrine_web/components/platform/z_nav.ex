defmodule ElektrineWeb.Components.Platform.ZNav do
  @moduledoc """
  Provides Z platform-specific UI components.

  Components for the social platform (chat, timeline, discussions) including navigation, posts, etc.
  """
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  import ElektrineWeb.CoreComponents

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  @doc """
  Renders the Z platform navigation tabs.

  ## Examples

      <.z_nav active_tab="chat" />
      <.z_nav active_tab="timeline" />
      <.z_nav active_tab="discussions" />

  """
  attr :active_tab, :string, required: true

  def z_nav(assigns) do
    ~H"""
    <div class="sticky top-16 z-40 card shadow-lg rounded-box border border-red-500/30 mb-6 py-2 px-2 sm:px-4 bg-base-100/80 backdrop-blur-md">
      <div class="flex items-center gap-2 sm:gap-4">
        <div class="flex flex-1 overflow-x-auto gap-1">
          <.link
            href={~p"/overview"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "overview" && "bg-secondary/15 text-secondary",
              @active_tab != "overview" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "overview", do: "hero-sparkles-solid", else: "hero-sparkles"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Overview")}</span>
          </.link>
          <.link
            href={~p"/friends"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "friends" && "bg-secondary/15 text-secondary",
              @active_tab != "friends" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "friends", do: "hero-user-group-solid", else: "hero-user-group"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Friends")}</span>
          </.link>
          <.link
            href={~p"/chat"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "chat" && "bg-secondary/15 text-secondary",
              @active_tab != "chat" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={
                if @active_tab == "chat",
                  do: "hero-chat-bubble-left-right-solid",
                  else: "hero-chat-bubble-left-right"
              }
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Chat")}</span>
          </.link>
          <.link
            href={~p"/timeline"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "timeline" && "bg-secondary/15 text-secondary",
              @active_tab != "timeline" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={
                if @active_tab == "timeline",
                  do: "hero-rectangle-stack-solid",
                  else: "hero-rectangle-stack"
              }
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Timeline")}</span>
          </.link>
          <.link
            href={~p"/lists"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "lists" && "bg-secondary/15 text-secondary",
              @active_tab != "lists" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "lists", do: "hero-queue-list-solid", else: "hero-queue-list"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Lists")}</span>
          </.link>
          <.link
            href={~p"/communities"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "discussions" && "bg-secondary/15 text-secondary",
              @active_tab != "discussions" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={
                if @active_tab == "discussions",
                  do: "hero-chat-bubble-bottom-center-text-solid",
                  else: "hero-chat-bubble-bottom-center-text"
              }
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Communities")}</span>
          </.link>
          <.link
            href={~p"/gallery"}
            class={[
              "flex items-center px-3 py-1.5 rounded-lg text-sm transition-colors whitespace-nowrap",
              @active_tab == "gallery" && "bg-secondary/15 text-secondary",
              @active_tab != "gallery" && "hover:bg-base-200"
            ]}
          >
            <.icon
              name={if @active_tab == "gallery", do: "hero-photo-solid", else: "hero-photo"}
              class="w-4 h-4 sm:mr-2"
            />
            <span class="hidden sm:inline">{gettext("Gallery")}</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
