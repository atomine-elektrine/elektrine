defmodule ElektrineWeb.Components.EmojiPicker do
  @moduledoc """
  A reusable emoji picker component with support for both
  Unicode emojis and custom emojis.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  # Popular Unicode emojis organized by category
  @emoji_categories %{
    "Recent" => [],
    "Smileys" => ~w(
      😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 ☺️ 😚 😙 🥲 😋 😛 😜
      🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 🤥 😌 😔 😪 🤤 😴 😷
    ),
    "Gestures" => ~w(
      👋 🤚 🖐️ ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 👍 👎 ✊ 👊 🤛
      🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💪 🦵 🦶 👂 🦻 👃 🧠 🫀 🫁 🦷 🦴 👀 👁️ 👅 👄
    ),
    "Hearts" => ~w(
      ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ❤️‍🔥 ❤️‍🩹 ♥️
    ),
    "Animals" => ~w(
      🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦
      🐤 🐣 🐥 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🪱 🐛 🦋 🐌 🐞 🐜 🪰 🪲 🪳 🦗 🦂
    ),
    "Food" => ~w(
      🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒
      🌶️ 🫑 🌽 🥕 🫒 🧄 🧅 🥔 🍠 🥐 🥖 🍞 🥨 🥯 🧇 🥞 🧈 🍳 🥚 🧀 🥓 🥩 🍗
    ),
    "Activities" => ~w(
      ⚽ 🏀 🏈 ⚾ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🪃 🥅 ⛳ 🪁 🏹 🎣
      🤿 🥊 🥋 🎽 🛹 🛼 🛷 ⛸️ 🥌 🎿 ⛷️ 🏂 🪂 🏋️ 🤼 🤸 🤺 ⛹️ 🤾 🏌️ 🏇 🧘
    ),
    "Objects" => ~w(
      ⌚ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 🖲️ 🕹️ 💽 💾 💿 📀 📼 📷 📸 📹 🎥 📽️ 🎞️ 📞 ☎️ 📟
      📠 📺 📻 🎙️ 🎚️ 🎛️ 🧭 ⏱️ ⏲️ ⏰ 🕰️ ⌛ ⏳ 📡 🔋 🔌 💡 🔦 🕯️ 🧯 🛢️ 💸
    ),
    "Symbols" => ~w(
      ❤️ 💯 💢 💥 💫 💦 💨 🕳️ 💬 👁️‍🗨️ 🗨️ 🗯️ 💭 💤 ✨ ⭐ 🌟 💫 ✅ ❎ ➕ ➖ ➗
      ❓ ❔ ❕ ❗ 〰️ 💱 💲 ⚕️ ♻️ ⚜️ 🔱 📛 🔰 ⭕ ✅ ☑️ ✔️ ❌ ❎ ➰ ➿ 〽️ ✳️ ✴️
    ),
    "Flags" => ~w(
      🏳️ 🏴 🏁 🚩 🏳️‍🌈 🏳️‍⚧️ 🇺🇳 🏴‍☠️
    )
  }

  @doc """
  Renders an emoji picker with tabs for categories and custom emoji support.

  ## Attributes
    * `id` - Required. A unique ID for the picker.
    * `on_select` - Required. Event name to fire when an emoji is selected.
    * `custom_emojis` - Optional. List of custom emoji structs to display.
    * `search_query` - Optional. Current search query.
    * `show_search` - Optional. Whether to show search box. Default true.
    * `categories` - Optional. Override default categories.

  ## Examples

      <.emoji_picker
        id="chat-emoji-picker"
        on_select="insert_emoji"
        custom_emojis={@custom_emojis}
      />
  """
  attr :id, :string, required: true
  attr :on_select, :string, required: true
  attr :custom_emojis, :list, default: []
  attr :search_query, :string, default: ""
  attr :show_search, :boolean, default: true
  attr :class, :string, default: ""

  def emoji_picker(assigns) do
    assigns = assign_new(assigns, :categories, fn -> @emoji_categories end)
    assigns = assign_new(assigns, :active_tab, fn -> "Smileys" end)

    # Filter emojis based on search
    filtered_emojis =
      if assigns.search_query != "" do
        search_emojis(assigns.search_query, assigns.categories, assigns.custom_emojis)
      else
        nil
      end

    assigns = assign(assigns, :filtered_emojis, filtered_emojis)

    ~H"""
    <div id={@id} class={["bg-base-200 rounded-lg border border-base-300", @class]}>
      <!-- Search Box -->
      <%= if @show_search do %>
        <div class="p-2 border-b border-base-300">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-2 top-1/2 -translate-y-1/2 w-4 h-4 text-base-content/40"
            />
            <input
              type="text"
              placeholder="Search emoji..."
              value={@search_query}
              phx-keyup="emoji_search"
              phx-debounce="200"
              name="emoji_query"
              class="input input-sm input-bordered w-full pl-8"
            />
          </div>
        </div>
      <% end %>
      
    <!-- Search Results or Category View -->
      <%= if @filtered_emojis do %>
        <div class="p-2">
          <div class="text-xs text-base-content/50 mb-2">Search Results</div>
          <div class="grid grid-cols-8 gap-1 max-h-40 overflow-y-auto">
            <%= for emoji <- @filtered_emojis do %>
              <%= if is_binary(emoji) do %>
                <button
                  type="button"
                  phx-click={@on_select}
                  phx-value-emoji={emoji}
                  class="btn btn-sm btn-ghost text-lg hover:bg-base-300 p-1"
                  title={emoji}
                >
                  {emoji}
                </button>
              <% else %>
                <button
                  type="button"
                  phx-click={@on_select}
                  phx-value-emoji={":#{emoji.shortcode}:"}
                  class="btn btn-sm btn-ghost hover:bg-base-300 p-1"
                  title={":" <> emoji.shortcode <> ":"}
                >
                  <img src={emoji.image_url} alt={emoji.shortcode} class="w-5 h-5" />
                </button>
              <% end %>
            <% end %>
          </div>
          <%= if Enum.empty?(@filtered_emojis) do %>
            <p class="text-center text-base-content/50 py-4 text-sm">No emojis found</p>
          <% end %>
        </div>
      <% else %>
        <!-- Category Tabs -->
        <div class="flex overflow-x-auto border-b border-base-300 px-1">
          <%= if !Enum.empty?(@custom_emojis) do %>
            <button
              type="button"
              phx-click="emoji_tab"
              phx-value-tab="Custom"
              class={[
                "px-3 py-2 text-sm whitespace-nowrap border-b-2 -mb-px",
                @active_tab == "Custom" && "border-secondary text-secondary",
                @active_tab != "Custom" && "border-transparent hover:border-base-300"
              ]}
            >
              Custom
            </button>
          <% end %>
          <%= for {category, _} <- @categories do %>
            <button
              type="button"
              phx-click="emoji_tab"
              phx-value-tab={category}
              class={[
                "px-3 py-2 text-sm whitespace-nowrap border-b-2 -mb-px",
                @active_tab == category && "border-secondary text-secondary",
                @active_tab != category && "border-transparent hover:border-base-300"
              ]}
            >
              {category}
            </button>
          <% end %>
        </div>
        
    <!-- Emoji Grid -->
        <div class="p-2">
          <%= if @active_tab == "Custom" && !Enum.empty?(@custom_emojis) do %>
            <div class="grid grid-cols-8 gap-1 max-h-40 overflow-y-auto">
              <%= for emoji <- @custom_emojis do %>
                <button
                  type="button"
                  phx-click={@on_select}
                  phx-value-emoji={":#{emoji.shortcode}:"}
                  class="btn btn-sm btn-ghost hover:bg-base-300 p-1"
                  title={":" <> emoji.shortcode <> ":"}
                >
                  <img src={emoji.image_url} alt={emoji.shortcode} class="w-5 h-5" />
                </button>
              <% end %>
            </div>
          <% else %>
            <div class="grid grid-cols-8 gap-1 max-h-40 overflow-y-auto">
              <%= for emoji <- Map.get(@categories, @active_tab, []) do %>
                <button
                  type="button"
                  phx-click={@on_select}
                  phx-value-emoji={emoji}
                  class="btn btn-sm btn-ghost text-lg hover:bg-base-300 p-1"
                  title={emoji}
                >
                  {emoji}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Search through both Unicode and custom emojis
  defp search_emojis(query, _categories, custom_emojis) do
    query = String.downcase(query)

    # Search custom emojis by shortcode
    matching_custom =
      custom_emojis
      |> Enum.filter(fn emoji ->
        String.contains?(String.downcase(emoji.shortcode), query)
      end)
      |> Enum.take(16)

    # For Unicode emojis, we can't really search by name without a mapping
    # So we'll just return custom emoji matches for now
    # In a full implementation, you'd want an emoji name -> unicode mapping

    matching_custom
  end
end
