defmodule ElektrineWeb.ProfileLive.EditSections do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile, :map, required: true
  attr :user, :map, required: true

  def profile_tab(assigns) do
    ~H"""
    <.profile_basic_information_card profile={@profile} user={@user} />
    <.profile_privacy_card profile={@profile} />
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
            <label class="cursor-pointer label justify-start gap-4">
              <input type="hidden" name="profile[show_birthday]" value="false" />
              <input
                type="checkbox"
                name="profile[show_birthday]"
                value="true"
                checked={@user.show_birthday}
                class="checkbox checkbox-primary"
              />
              <span class="label-text">
                <span class="font-semibold">Show birthday on profile</span>
                <span class="text-sm text-base-content/70 block">
                  Display your birthday publicly on your profile
                </span>
              </span>
            </label>
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

          <button type="submit" class="btn btn-primary w-full"> Save Profile </button>
        </.form>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true

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
          <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
            Social Counts
          </div>

          <div class="space-y-4">
            <.privacy_checkbox
              field="hide_view_counter"
              checked={@profile.hide_view_counter}
              title="Hide view counter"
              description="Don't show how many people have visited your profile"
            />

            <.privacy_group_heading>Identifiers</.privacy_group_heading>

            <.privacy_checkbox
              field="hide_uid"
              checked={@profile.hide_uid}
              title="Hide user ID"
              description="Don't show your numeric user ID on your profile"
            />

            <.privacy_group_heading>Social Graph</.privacy_group_heading>

            <p class="text-sm text-base-content/70">
              Follower, following, and favorites visibility is managed in <.link
                navigate={~p"/account?tab=privacy"}
                class="link link-primary"
              >
                Account Settings &rarr; Privacy
              </.link>.
            </p>

            <.privacy_group_heading>Visibility</.privacy_group_heading>
            <.privacy_group_heading>Sharing</.privacy_group_heading>

            <.privacy_checkbox
              field="hide_avatar"
              checked={@profile.hide_avatar}
              title="Hide avatar & display name"
              description="Don't show your avatar and display name"
            />

            <.privacy_group_heading>Layout</.privacy_group_heading>

            <.privacy_checkbox
              field="hide_timeline"
              checked={@profile.hide_timeline}
              title="Hide timeline"
              description="Don't show your timeline posts on your profile"
            />

            <.privacy_checkbox
              field="hide_community_posts"
              checked={@profile.hide_community_posts}
              title="Hide community posts"
              description="Don't show your community/discussion posts on your profile"
            />

            <.privacy_checkbox
              field="hide_share_button"
              checked={@profile.hide_share_button}
              title="Hide share button"
              description="Don't show the share button on your profile (includes QR code)"
            />

            <.privacy_checkbox
              field="extend_layout"
              checked={@profile.extend_layout}
              title="Extend layout to bottom"
              description="Make the profile extend to the bottom of the screen"
            />
          </div>
          <button type="submit" class="btn btn-primary w-full"> Save Privacy </button>
        </.form>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  defp privacy_group_heading(assigns) do
    ~H"""
    <div class="pt-2 text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :field, :string, required: true
  attr :checked, :boolean, default: false
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp privacy_checkbox(assigns) do
    ~H"""
    <div class="form-control">
      <label class="cursor-pointer label justify-start gap-4">
        <input type="hidden" name={"profile[#{@field}]"} value="false" />
        <input
          type="checkbox"
          name={"profile[#{@field}]"}
          value="true"
          checked={@checked}
          class="checkbox checkbox-primary"
        />
        <span class="label-text">
          <span class="font-semibold">{@title}</span>
          <span class="text-sm text-base-content/70 block">
            {@description}
          </span>
        </span>
      </label>
    </div>
    """
  end
end
