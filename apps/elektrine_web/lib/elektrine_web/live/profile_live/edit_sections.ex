defmodule ElektrineWeb.ProfileLive.EditSections do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile, :map, required: true
  attr :user, :map, required: true

  def profile_tab(assigns) do
    ~H"""
    <.profile_basic_information_card profile={@profile} user={@user} />
    <.profile_privacy_card profile={@profile} user={@user} />
    <.profile_federation_card profile={@profile} user={@user} />
    """
  end

  attr :profile, :map, required: true
  attr :user, :map, required: true

  defp profile_basic_information_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-user" class="w-6 h-6" /> Basic Information
          </h2>

          <p class="text-sm text-base-content/60">
            Your profile details and privacy settings
          </p>
        </div>

        <.form
          for={%{}}
          phx-submit="update_profile"
          phx-change="validate_profile"
          multipart
          class="space-y-4 sm:space-y-6"
        >
          <div>
            <label class="label">
              <span class="label-text font-medium">Display Name</span>
            </label>
            <input
              type="text"
              name="profile[display_name]"
              value={@profile.display_name || @user.username}
              placeholder="Display name"
              class="input input-bordered w-full"
              maxlength="50"
            />
            <div class="label">
              <span class="text-xs text-base-content/60">Keep it short and memorable</span>
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text font-medium">Bio Description</span>
            </label>
            <div class="tabs tabs-boxed mb-2">
              <button type="button" data-show-tab="edit" id="edit-tab" class="tab tab-active">
                Edit
              </button>
              <button type="button" data-show-tab="preview" id="preview-tab" class="tab">
                Preview
              </button>
            </div>

            <div id="markdown-edit" class="">
              <textarea
                name="profile[description]"
                id="description-textarea"
                class="textarea textarea-bordered w-full"
                rows="4"
                placeholder="Tell people about yourself..."
                maxlength="1000"
                data-markdown-preview-input
              ><%= @profile.description || "" %></textarea>
            </div>

            <div id="markdown-preview" class="hidden">
              <div class="bg-base-200 rounded-lg p-4 min-h-24 prose prose-sm max-w-none">
                <div id="preview-content">
                  <%= if @profile.description do %>
                    {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@profile.description))}
                  <% else %>
                    <p class="text-base-content/50 italic">Preview will appear here...</p>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="label">
              <span class="text-xs text-base-content/60">
                Markdown supported - **bold**, *italic*, [links](url). Max 1000 characters.
              </span>
            </div>
          </div>

          <div>
            <label class="label"><span class="label-text font-medium">Location</span></label>
            <input
              type="text"
              name="profile[location]"
              value={@profile.location || ""}
              placeholder="City, Country, or Remote"
              class="input input-bordered w-full"
              maxlength="100"
            />
            <div class="label">
              <span class="text-xs text-base-content/60"> Where are you based? </span>
            </div>
          </div>

          <div>
            <label class="label"><span class="label-text font-medium">Birthday</span></label>
            <input
              type="date"
              name="profile[birthday]"
              value={@user.birthday}
              max={Date.utc_today()}
              class="input input-bordered w-full"
            />
            <div class="label">
              <span class="text-xs text-base-content/60"> Optional. Leave blank to remove. </span>
            </div>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Birthday visibility</span>
            </label>
            <select name="profile[show_birthday]" class="select select-bordered w-full">
              <option value="true" selected={@user.show_birthday == true}>Show full date</option>
              <option value="false" selected={@user.show_birthday != true}>Hidden</option>
            </select>
            <div class="label">
              <span class="text-xs text-base-content/60">
                Month-and-day-only display needs a separate saved preference.
              </span>
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text font-medium">Page Title</span>
            </label>
            <input
              type="text"
              name="profile[page_title]"
              value={@profile.page_title || ""}
              placeholder={"#{@user.handle || @user.username}'s Profile"}
              class="input input-bordered w-full"
              maxlength="100"
            />
            <div class="label">
              <span class="text-xs text-base-content/60">
                Custom browser tab title. Enable the typewriter effect in Effects.
              </span>
            </div>
          </div>

          <div class="rounded-lg border border-base-content/10 bg-base-200/30 p-4">
            <div class="mb-4">
              <h3 class="font-semibold">Profile Image Metadata</h3>
              <p class="mt-1 text-sm text-base-content/60">
                Alt text and focal points for avatar and banner assets.
              </p>
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="md:col-span-2">
                <label class="label">
                  <span class="label-text font-medium">Avatar alt text</span>
                </label>
                <input
                  type="text"
                  name="profile[avatar_alt_text]"
                  value={@profile.avatar_alt_text}
                  maxlength="250"
                  class="input input-bordered w-full"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Avatar focal X</span>
                  <span class="label-text-alt">{round(@profile.avatar_focal_x || 50)}%</span>
                </label>
                <input
                  type="range"
                  name="profile[avatar_focal_x]"
                  min="0"
                  max="100"
                  step="1"
                  value={@profile.avatar_focal_x || 50}
                  class="range range-primary"
                />
              </div>

              <div>
                <label class="label">
                  <span class="label-text font-medium">Avatar focal Y</span>
                  <span class="label-text-alt">{round(@profile.avatar_focal_y || 50)}%</span>
                </label>
                <input
                  type="range"
                  name="profile[avatar_focal_y]"
                  min="0"
                  max="100"
                  step="1"
                  value={@profile.avatar_focal_y || 50}
                  class="range range-primary"
                />
              </div>

              <div class="md:col-span-2">
                <label class="label">
                  <span class="label-text font-medium">Banner alt text</span>
                </label>
                <input
                  type="text"
                  name="profile[banner_alt_text]"
                  value={@profile.banner_alt_text}
                  maxlength="250"
                  class="input input-bordered w-full"
                />
              </div>
            </div>
          </div>

          <button type="submit" class="btn btn-primary w-full"> Save Profile </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :user, :map, required: true

  defp profile_privacy_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-eye-slash" class="w-6 h-6" /> Privacy
          </h2>

          <p class="text-sm text-base-content/60">
            Decide what visitors can see on your public profile.
          </p>
        </div>

        <.form
          for={%{}}
          phx-submit="update_profile"
          phx-change="validate_profile"
          class="space-y-4 sm:space-y-6"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.visibility_select
              name="profile[profile_visibility]"
              label="Profile access"
              description="Controls who can open your profile page."
              value={@user.profile_visibility || "public"}
              options={[
                {"public", "Public"},
                {"followers", "Followers only"},
                {"private", "Hidden from others"}
              ]}
            />

            <.visibility_select
              name="profile[identity_visibility]"
              label="Avatar and display name"
              description="Show or hide your profile identity block."
              value={if @profile.hide_avatar, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[timeline_visibility]"
              label="Timeline"
              description="Show or hide timeline posts on the profile page."
              value={if @profile.hide_timeline, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[community_posts_visibility]"
              label="Community posts"
              description="Show or hide discussion/community posts."
              value={if @profile.hide_community_posts, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[view_counter_visibility]"
              label="View counter"
              description="Show or hide profile page views."
              value={if @profile.hide_view_counter, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[uid_visibility]"
              label="User ID"
              description="Show or hide your numeric account ID."
              value={if @profile.hide_uid, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[share_visibility]"
              label="Share tools"
              description="Show or hide the public share and QR controls."
              value={if @profile.hide_share_button, do: "hidden", else: "public"}
              options={[{"public", "Public"}, {"hidden", "Hidden"}]}
            />

            <.visibility_select
              name="profile[layout_height]"
              label="Layout height"
              description="Choose whether the profile container fills short screens."
              value={if @profile.extend_layout, do: "extended", else: "content"}
              options={[{"extended", "Extend to viewport"}, {"content", "Fit content"}]}
            />
          </div>

          <div class="rounded-lg border border-base-content/10 bg-base-200/35 p-4 text-sm text-base-content/70">
            Follower, following, and favorites visibility is managed in <.link
              navigate={~p"/account?tab=privacy"}
              class="link link-primary"
            >
              Account Settings &rarr; Privacy
            </.link>.
          </div>

          <button type="submit" class="btn btn-primary w-full"> Save Privacy </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true

  defp visibility_select(assigns) do
    ~H"""
    <div>
      <label class="label">
        <span class="label-text font-medium">{@label}</span>
      </label>
      <select name={@name} class="select select-bordered w-full">
        <%= for {value, label} <- @options do %>
          <option value={value} selected={@value == value}>{label}</option>
        <% end %>
      </select>
      <div class="label">
        <span class="text-xs text-base-content/60">{@description}</span>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :user, :map, required: true

  defp profile_federation_card(assigns) do
    ~H"""
    <div class="card panel-card">
      <div class="card-body p-4 sm:p-6">
        <div class="mb-6">
          <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
            <.icon name="hero-globe-alt" class="w-6 h-6" /> Federation Preview
          </h2>

          <p class="text-sm text-base-content/60">
            See what remote ActivityPub servers can receive from your profile.
          </p>
        </div>

        <div class="grid gap-4 lg:grid-cols-2">
          <div class="rounded-lg border border-base-content/10 bg-base-100/70 p-4">
            <div class="mb-3 flex items-center justify-between gap-3">
              <h3 class="font-semibold">Federated actor</h3>
              <span class="badge badge-outline">{@user.profile_visibility || "public"}</span>
            </div>

            <dl class="space-y-3 text-sm">
              <div>
                <dt class="text-base-content/55">Handle</dt>
                <dd class="font-mono">
                  @{@user.username}@{URI.parse(Elektrine.ActivityPub.instance_url()).host}
                </dd>
              </div>
              <div>
                <dt class="text-base-content/55">Display name</dt>
                <dd>{@profile.display_name || @user.display_name || @user.username}</dd>
              </div>
              <div>
                <dt class="text-base-content/55">Bio</dt>
                <dd>
                  {if Elektrine.Strings.present?(@profile.description), do: "Federated", else: "Empty"}
                </dd>
              </div>
              <div>
                <dt class="text-base-content/55">Links</dt>
                <dd>
                  {active_federated_link_count(@profile)} active profile links export as ActivityPub attachments.
                </dd>
              </div>
            </dl>
          </div>

          <div class="rounded-lg border border-base-content/10 bg-base-100/70 p-4">
            <h3 class="mb-3 font-semibold">Local-only profile features</h3>
            <ul class="space-y-2 text-sm text-base-content/70">
              <li class="flex gap-2">
                <.icon name="hero-check-circle" class="mt-0.5 h-4 w-4 text-success" />
                Theme colors, effects, cursors, and profile layout.
              </li>
              <li class="flex gap-2">
                <.icon name="hero-check-circle" class="mt-0.5 h-4 w-4 text-success" />
                Widgets, static-site files, publish mode, and site file manager.
              </li>
              <li class="flex gap-2">
                <.icon name="hero-check-circle" class="mt-0.5 h-4 w-4 text-success" />
                View counters, user ID display, share controls, and QR code visibility.
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp active_federated_link_count(profile) do
    profile
    |> Map.get(:links, [])
    |> Enum.count(&Map.get(&1, :is_active, false))
  end
end
