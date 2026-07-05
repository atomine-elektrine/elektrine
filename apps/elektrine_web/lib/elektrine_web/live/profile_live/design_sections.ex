defmodule ElektrineWeb.ProfileLive.DesignSections do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile, :map, required: true

  def design_intro_cards(assigns) do
    ~H"""
    <.theme_presets_card />
    <.quick_color_palette_card profile={@profile} />
    """
  end

  defp theme_presets_card(assigns) do
    ~H"""
    <div class="card panel-card border-2 border-primary/20">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
              <.icon name="hero-swatch" class="w-6 h-6" /> Theme Presets
            </h2>

            <p class="text-sm text-base-content/60">
              Start with a complete look, then fine-tune the details below.
            </p>
          </div>
          <button
            type="button"
            phx-click="reset_design_section"
            phx-value-section="all"
            class="btn btn-ghost btn-sm"
          >
            Reset all design
          </button>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <%= for {preset_id, preset_name, preset_description} <- design_presets() do %>
            <button
              type="button"
              phx-click="apply_design_preset"
              phx-value-preset={preset_id}
              class="rounded-xl border border-base-content/10 bg-base-100 p-4 text-left transition hover:border-primary/40 hover:bg-primary/5"
            >
              <div class="font-semibold">{preset_name}</div>
              <p class="mt-1 text-sm text-base-content/60">{preset_description}</p>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true

  defp quick_color_palette_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-sparkles" class="w-6 h-6" /> Quick Color Palette
          </h2>

          <p class="text-sm text-base-content/60">
            Pick one color and we'll generate a matching palette
          </p>
        </div>

        <.form for={%{}} phx-submit="generate_palette" class="space-y-4 sm:space-y-6">
          <div class="flex items-center gap-4">
            <input
              type="color"
              name="base_color"
              value={
                @profile.accent_color ||
                  Elektrine.Profiles.UserProfile.default(:accent_color)
              }
              class="w-24 h-24 border-0 rounded-xl cursor-pointer"
            />
            <div class="flex-1">
              <p class="font-semibold text-lg">Base Color</p>

              <p class="text-sm text-base-content/70">
                We'll create a harmonious color scheme based on this
              </p>
            </div>
          </div>

          <button type="submit" class="btn btn-primary w-full btn-lg">
            <.icon name="hero-sparkles" class="w-5 h-5 mr-2" /> Generate Matching Palette
          </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :uploads, :map, required: true

  def design_background_upload_card(assigns) do
    ~H"""
    <%= if @profile.background_type in ["image", "video"] do %>
      <div class="card panel-card">
        <div class="card-body p-4 sm:p-6">
          <h2 class="card-title text-lg sm:text-xl mb-4 flex items-center gap-2">
            <.icon name="hero-photo" class="w-5 h-5" /> Upload Background
          </h2>

          <p class="text-sm text-base-content/60 mb-4">
            <%= if @profile.background_type == "video" do %>
              Upload a video background (MP4 or WebM, max 10MB)
            <% else %>
              Upload an image background (JPG, PNG, GIF, or WebP, max 10MB)
            <% end %>
          </p>

          <.form
            for={%{}}
            phx-submit="update_profile"
            phx-change="validate_background_upload"
            class="space-y-4"
          >
            <%= if @profile.background_url do %>
              <div class="space-y-2">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-sm font-medium">Current background</div>
                    <div class="text-xs text-base-content/60">
                      {if @profile.background_type == "video", do: "Video", else: "Image"} · {format_upload_bytes(
                        @profile.background_size || 0
                      )}
                    </div>
                  </div>

                  <button
                    type="button"
                    phx-click="remove_background"
                    class="btn btn-outline btn-error btn-sm"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> Remove
                  </button>
                </div>

                <div class="relative overflow-hidden rounded-lg border border-base-content/10">
                  <%= if @profile.background_type == "video" do %>
                    <video
                      src={Elektrine.Uploads.background_url(@profile.background_url)}
                      class="h-48 w-full object-cover"
                      autoplay
                      loop
                      muted
                    >
                    </video>
                  <% else %>
                    <img
                      src={Elektrine.Uploads.background_url(@profile.background_url)}
                      alt={@profile.background_alt_text || "Current background"}
                      class="h-48 w-full object-cover"
                      style={"object-position: #{@profile.background_focal_x || 50}% #{@profile.background_focal_y || 50}%;"}
                    />
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= for entry <- @uploads.background.entries do %>
              <div class="space-y-2 rounded-lg bg-base-200 p-3">
                <div class="flex items-center gap-2">
                  <.icon
                    name={if @profile.background_type == "video", do: "hero-film", else: "hero-photo"}
                    class="w-6 h-6 flex-shrink-0"
                  />
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium truncate">{entry.client_name}</p>
                    <p class="text-xs text-base-content/60">
                      {format_upload_bytes(entry.client_size || 0)}
                    </p>

                    <progress
                      class="progress progress-primary w-full h-2 mt-1"
                      value={entry.progress}
                      max="100"
                    >
                    </progress>
                  </div>

                  <button
                    type="button"
                    phx-click="cancel_background_upload"
                    phx-value-ref={entry.ref}
                    class="btn btn-ghost btn-sm btn-circle flex-shrink-0"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>

                <div
                  :if={upload_size_notice(entry)}
                  class="rounded-md border border-warning/25 bg-warning/10 p-2 text-xs text-warning"
                >
                  {upload_size_notice(entry)}
                </div>
              </div>
            <% end %>

            <div class="rounded-lg border border-base-content/10 bg-base-200/35 p-3 text-sm text-base-content/70">
              Replacing uploads overwrite the current background after Save. Focal point controls how
              image and video backgrounds are cropped across screen sizes.
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="md:col-span-2">
                <label class="label">
                  <span class="label-text font-medium">Background alt text</span>
                </label>
                <input
                  type="text"
                  name="profile[background_alt_text]"
                  value={@profile.background_alt_text}
                  maxlength="250"
                  class="input input-bordered w-full"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Focal point X</span>
                  <span class="label-text-alt">{round(@profile.background_focal_x || 50)}%</span>
                </label>
                <input
                  type="range"
                  name="profile[background_focal_x]"
                  min="0"
                  max="100"
                  step="1"
                  value={@profile.background_focal_x || 50}
                  class="range range-primary"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Focal point Y</span>
                  <span class="label-text-alt">{round(@profile.background_focal_y || 50)}%</span>
                </label>
                <input
                  type="range"
                  name="profile[background_focal_y]"
                  min="0"
                  max="100"
                  step="1"
                  value={@profile.background_focal_y || 50}
                  class="range range-primary"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Brightness</span>
                  <span class="label-text-alt">{@profile.background_brightness || 100}%</span>
                </label>
                <input
                  type="range"
                  name="profile[background_brightness]"
                  min="25"
                  max="150"
                  step="5"
                  value={@profile.background_brightness || 100}
                  class="range range-primary"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Background blur</span>
                  <span class="label-text-alt">{@profile.background_overlay_blur || 0}px</span>
                </label>
                <input
                  type="range"
                  name="profile[background_overlay_blur]"
                  min="0"
                  max="40"
                  step="1"
                  value={@profile.background_overlay_blur || 0}
                  class="range range-primary"
                />
              </div>
            </div>

            <label class="btn btn-ghost w-full">
              <.icon name="hero-arrow-up-tray" class="w-5 h-5 mr-2" />
              Replace with {if @profile.background_type == "video", do: "Video", else: "Image"}
              <.live_file_input upload={@uploads.background} class="hidden" />
            </label>
            <button type="submit" class="btn btn-primary w-full">
              Save Background
            </button>
          </.form>
        </div>
      </div>
    <% end %>
    """
  end

  defp upload_size_notice(%{client_size: size})
       when is_integer(size) and size > 8 * 1024 * 1024 do
    "Large file warning: #{format_upload_bytes(size)} may load slowly on mobile profiles."
  end

  defp upload_size_notice(_entry), do: nil

  defp format_upload_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_upload_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_upload_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_upload_bytes(_bytes), do: "0 B"

  attr :profile, :map, required: true

  def design_motion_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
              <.icon name="hero-adjustments-horizontal" class="w-6 h-6" /> Motion & Transparency
            </h2>

            <p class="text-sm text-base-content/60">
              Adjust transparency, blur, and pattern strength.
            </p>
          </div>
          <button
            type="button"
            phx-click="reset_design_section"
            phx-value-section="motion"
            class="btn btn-ghost btn-sm"
          >
            Reset motion
          </button>
        </div>

        <.form for={%{}} phx-submit="update_profile" multipart class="space-y-4 sm:space-y-6">
          <div class="space-y-4 sm:space-y-6">
            <div>
              <label class="label">
                <span class="label-text font-medium">Card transparency</span>
                <span class="label-text-alt">
                  {round((@profile.profile_opacity || 1.0) * 100)}%
                </span>
              </label>
              <input
                type="range"
                name="profile[profile_opacity]"
                min="0.5"
                max="1"
                step="0.1"
                value={@profile.profile_opacity || 1.0}
                phx-change="update_effect"
                phx-value-field="profile_opacity"
                class="range range-primary w-full"
              />
              <div class="flex w-full justify-between text-xs text-base-content/60">
                <span>50%</span> <span>75%</span> <span>100%</span>
              </div>
            </div>

            <div>
              <label class="label">
                <span class="label-text font-medium">Background blur</span>
                <span class="label-text-alt">
                  {@profile.profile_blur || 0}px
                </span>
              </label>
              <input
                type="range"
                name="profile[profile_blur]"
                min="0"
                max="20"
                step="1"
                value={@profile.profile_blur || 0}
                phx-change="update_effect"
                phx-value-field="profile_blur"
                class="range range-primary w-full"
              />
              <div class="flex w-full justify-between text-xs text-base-content/60">
                <span>0px</span> <span>10px</span> <span>20px</span>
              </div>
            </div>

            <div>
              <label class="label">
                <span class="label-text font-medium">Card background transparency</span>
                <span class="label-text-alt">
                  {round((@profile.container_opacity || 0.4) * 100)}%
                </span>
              </label>
              <input
                type="range"
                name="profile[container_opacity]"
                min="0"
                max="1"
                step="0.1"
                value={@profile.container_opacity || 0.4}
                phx-change="update_effect"
                phx-value-field="container_opacity"
                class="range range-primary w-full"
              />
              <div class="flex w-full justify-between text-xs text-base-content/60">
                <span>0%</span> <span>50%</span> <span>100%</span>
              </div>
            </div>

            <%= if @profile.container_pattern && @profile.container_pattern != "none" do %>
              <div>
                <label class="label">
                  <span class="label-text font-medium">Pattern strength</span>
                  <span class="label-text-alt">
                    {round((@profile.pattern_opacity || 0.2) * 100)}%
                  </span>
                </label>
                <input
                  type="range"
                  name="profile[pattern_opacity]"
                  min="0.0"
                  max="1.0"
                  step="0.1"
                  value={@profile.pattern_opacity || 0.2}
                  phx-change="update_effect"
                  phx-value-field="pattern_opacity"
                  class="range range-primary w-full"
                />
                <div class="flex w-full justify-between text-xs text-base-content/60">
                  <span>0%</span> <span>50%</span> <span>100%</span>
                </div>
              </div>
            <% end %>
          </div>
          <button type="submit" class="btn btn-primary w-full"> Save motion </button>
        </.form>
      </div>
    </div>
    """
  end

  defp design_presets do
    [
      {"minimal", "Minimal", "Clean white card with a quiet blue accent"},
      {"terminal", "Terminal", "Dark console-inspired profile"},
      {"neon", "Neon", "High-energy dark theme with pink and cyan"},
      {"soft", "Soft", "Warm pastel profile with gentle contrast"},
      {"high_contrast", "High Contrast", "Sharp black, white, and yellow palette"},
      {"creator", "Creator", "Card-forward theme for links and media"}
    ]
  end
end
