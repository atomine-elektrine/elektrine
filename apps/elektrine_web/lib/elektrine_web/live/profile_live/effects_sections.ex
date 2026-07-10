defmodule ElektrineWeb.ProfileLive.EffectsSections do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile, :map, required: true

  def effects_tab(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-6">
      <.typewriter_effect_card profile={@profile} />
      <.avatar_effects_card profile={@profile} />
      <.username_effects_card profile={@profile} />
    </div>
    """
  end

  attr :profile, :map, required: true

  defp typewriter_effect_card(assigns) do
    ~H"""
    <.card body_class="p-4 sm:p-6">
      <:body>
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-pencil-square" class="w-6 h-6" /> Typewriter Effect
          </h2>

          <p class="text-sm text-base-content/60">
            Animate your bio with a typewriter effect
          </p>
        </div>

        <.form for={%{}} phx-submit="update_profile" class="space-y-4 sm:space-y-6">
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input type="hidden" name="profile[typewriter_title]" value="false" />
              <input
                type="checkbox"
                name="profile[typewriter_title]"
                value="true"
                checked={@profile.typewriter_title}
                class="checkbox checkbox-primary"
              />
              <span class="label-text">
                <span class="font-semibold">Typewriter for Browser Tab Title</span>
                <span class="text-sm text-base-content/70 block">
                  Animate the page title in the browser tab (requires Page Title to be set in Profile)
                </span>
              </span>
            </label>
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input type="hidden" name="profile[typewriter_effect]" value="false" />
              <input
                type="checkbox"
                name="profile[typewriter_effect]"
                value="true"
                checked={@profile.typewriter_effect}
                class="checkbox checkbox-primary"
              />
              <span class="label-text">
                <span class="font-semibold">Typewriter for Bio</span>
                <span class="text-sm text-base-content/70 block">
                  Animate your bio description when visitors load your profile
                </span>
              </span>
            </label>
          </div>

          <%= if @profile && (@profile.typewriter_effect || @profile.typewriter_title) do %>
            <div>
              <label class="label">
                <span class="label-text font-medium">Typing Speed</span>
              </label>
              <div class="select select-bordered w-full">
                <select name="profile[typewriter_speed]">
                  <option value="slow" selected={@profile.typewriter_speed == "slow"}>
                    Slow
                  </option>

                  <option
                    value="normal"
                    selected={@profile.typewriter_speed == "normal" || !@profile.typewriter_speed}
                  >
                    Normal
                  </option>

                  <option value="fast" selected={@profile.typewriter_speed == "fast"}>
                    Fast
                  </option>
                </select>
              </div>
            </div>
          <% end %>

          <.button type="submit" class="w-full">
            Save Typewriter Settings
          </.button>
        </.form>
      </:body>
    </.card>
    """
  end

  attr :profile, :map, required: true

  defp avatar_effects_card(assigns) do
    ~H"""
    <.card body_class="p-4 sm:p-6">
      <:body>
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-photo" class="w-6 h-6" /> Avatar Effects
          </h2>

          <p class="text-sm text-base-content/60">
            Add animated effects to your profile avatar
          </p>
        </div>

        <.form for={%{}} phx-submit="update_profile" class="space-y-4 sm:space-y-6">
          <div>
            <label class="label">
              <span class="label-text font-medium">Choose Effect</span>
            </label>
            <div class="select select-bordered w-full">
              <select name="profile[avatar_effect]">
                <option value="none" selected={@profile.avatar_effect == "none"}>None</option>
                <option value="glow" selected={@profile.avatar_effect == "glow"}>Glow Pulse</option>
                <option value="rainbow" selected={@profile.avatar_effect == "rainbow"}>
                  Rainbow Border
                </option>
                <option value="fire" selected={@profile.avatar_effect == "fire"}>Fire Ring</option>
                <option value="ice" selected={@profile.avatar_effect == "ice"}>Ice Shimmer</option>
                <option value="sparkle" selected={@profile.avatar_effect == "sparkle"}>
                  Sparkle
                </option>
                <option value="holographic" selected={@profile.avatar_effect == "holographic"}>
                  Holographic
                </option>
                <option value="gold_frame" selected={@profile.avatar_effect == "gold_frame"}>
                  Imperial Gold
                </option>
                <option value="pulse" selected={@profile.avatar_effect == "pulse"}>Pulse</option>
                <option value="rotate_border" selected={@profile.avatar_effect == "rotate_border"}>
                  Rotating Border
                </option>
              </select>
            </div>
            <p class="text-xs text-base-content/60 mt-2">
              Effects will use your profile's accent color. Save to preview on your profile.
            </p>
          </div>

          <.button type="submit" class="w-full">Save Avatar Effects</.button>
        </.form>
      </:body>
    </.card>
    """
  end

  attr :profile, :map, required: true

  defp username_effects_card(assigns) do
    ~H"""
    <.card body_class="p-4 sm:p-6">
      <:body>
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-sparkles" class="w-6 h-6" /> Username Effects
          </h2>

          <p class="text-sm text-base-content/60">
            Make your username stand out across the platform
          </p>
        </div>

        <.form for={%{}} phx-submit="update_profile" class="space-y-4 sm:space-y-6">
          <div>
            <label class="label">
              <span class="label-text font-medium">Choose Effect</span>
            </label>
            <div class="select select-bordered w-full">
              <select name="profile[username_effect]" phx-change="update_username_effect">
                <%= for {value, label} <- username_effect_options() do %>
                  <option value={value} selected={@profile.username_effect == value}>
                    {label}
                  </option>
                <% end %>
              </select>
            </div>
          </div>

          <%= if @profile.username_effect in ["glow", "neon", "outline", "pixelated"] do %>
            <div class="space-y-4 p-4 bg-base-200/50 rounded-lg">
              <div class="flex items-center gap-4">
                <input
                  type="color"
                  name="profile[username_glow_color]"
                  value={
                    @profile.username_glow_color ||
                      Elektrine.Profiles.UserProfile.default(:username_glow_color)
                  }
                  phx-change="update_username_color"
                  phx-value-field="username_glow_color"
                  class="w-16 h-16 border-0 rounded-lg cursor-pointer"
                />
                <div class="flex-1">
                  <p class="font-medium">Glow Color</p>

                  <p class="text-sm text-base-content/70">
                    Choose the color for your glow effect
                  </p>
                </div>
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Glow Intensity</span>
                  <span class="label-text-alt">{@profile.username_glow_intensity || 10}px</span>
                </label>
                <input
                  type="range"
                  name="profile[username_glow_intensity]"
                  min="0"
                  max="50"
                  step="5"
                  value={@profile.username_glow_intensity || 10}
                  phx-change="update_username_effect"
                  class="range range-primary w-full"
                />
                <div class="flex w-full justify-between text-xs text-base-content/60">
                  <span>Subtle</span> <span>Medium</span> <span>Intense</span>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @profile.username_effect in ["shadow", "double"] do %>
            <div class="p-4 bg-base-200/50 rounded-lg">
              <div class="flex items-center gap-4">
                <input
                  type="color"
                  name="profile[username_shadow_color]"
                  value={
                    @profile.username_shadow_color ||
                      Elektrine.Profiles.UserProfile.default(:username_shadow_color)
                  }
                  phx-change="update_username_color"
                  phx-value-field="username_shadow_color"
                  class="w-16 h-16 border-0 rounded-lg cursor-pointer"
                />
                <div class="flex-1">
                  <p class="font-medium">Shadow Color</p>

                  <p class="text-sm text-base-content/70">Choose the shadow color</p>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @profile.username_effect == "gradient" do %>
            <div class="p-4 bg-base-200/50 rounded-lg space-y-4">
              <p class="font-medium">Gradient Colors</p>

              <div class="grid grid-cols-2 gap-4">
                <.gradient_color_input
                  field="username_gradient_from"
                  value={
                    @profile.username_gradient_from ||
                      Elektrine.Profiles.UserProfile.default(:username_glow_color)
                  }
                  label="From"
                  description="Start color"
                />

                <.gradient_color_input
                  field="username_gradient_to"
                  value={
                    @profile.username_gradient_to || Elektrine.Theme.default_value("color_secondary")
                  }
                  label="To"
                  description="End color"
                />
              </div>
            </div>
          <% end %>

          <%= if @profile.username_effect in ["rainbow", "glitch", "neon", "fire", "ice", "holographic"] do %>
            <div>
              <label class="label">
                <span class="label-text font-medium">Animation Speed</span>
              </label>
              <div class="select select-bordered w-full">
                <select name="profile[username_animation_speed]">
                  <option value="slow" selected={@profile.username_animation_speed == "slow"}>
                    Slow
                  </option>

                  <option
                    value="normal"
                    selected={
                      @profile.username_animation_speed == "normal" ||
                        !@profile.username_animation_speed
                    }
                  >
                    Normal
                  </option>

                  <option value="fast" selected={@profile.username_animation_speed == "fast"}>
                    Fast
                  </option>
                </select>
              </div>
            </div>
          <% end %>

          <.button type="submit" class="w-full">
            Save Username Effects
          </.button>
        </.form>
      </:body>
    </.card>
    """
  end

  attr :field, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp gradient_color_input(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <input
        type="color"
        name={"profile[#{@field}]"}
        value={@value}
        phx-change="update_username_color"
        phx-value-field={@field}
        class="w-14 h-14 border-0 rounded-lg cursor-pointer"
      />
      <div>
        <p class="font-medium text-sm">{@label}</p>

        <p class="text-xs text-base-content/70">{@description}</p>
      </div>
    </div>
    """
  end

  defp username_effect_options do
    [
      {"none", "None"},
      {"glow", "Glow"},
      {"neon", "Neon"},
      {"rainbow", "Rainbow"},
      {"fire", "Fire"},
      {"ice", "Ice"},
      {"chrome", "Chrome"},
      {"holographic", "Holographic"},
      {"gradient", "Custom Gradient"},
      {"outline", "Outline"},
      {"shadow", "Drop Shadow"},
      {"double", "Double Text"},
      {"retro", "Retro VHS"},
      {"pixelated", "Pixelated"},
      {"glitch", "Glitch"}
    ]
  end
end
