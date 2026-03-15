defmodule ElektrineWeb.Components.Profile.Modals do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile_static, :boolean, required: true
  attr :profile_url, :string, required: true
  attr :user, :map, required: true

  def profile_share_modal_body(assigns) do
    assigns =
      assigns
      |> assign(:copy_button_attrs, copy_button_attrs(assigns.profile_static))
      |> assign(:qr_code, build_qr_code(assigns.profile_url))

    ~H"""
    <div class="mb-6 flex justify-center">
      <%= if @qr_code do %>
        <div class="inline-block rounded-lg bg-white p-3 border-2 border-base-300 shadow-lg">
          {Phoenix.HTML.raw(@qr_code)}
        </div>
      <% end %>
    </div>

    <div class="mb-6">
      <label class="block text-sm font-medium mb-2">Profile URL</label>
      <div class="flex gap-2">
        <input
          type="text"
          readonly
          value={@profile_url}
          id="profile-share-url"
          class="input input-bordered flex-1 text-sm"
        />
        <button
          class="btn btn-primary btn-square"
          title="Copy to clipboard"
          {@copy_button_attrs}
        >
          <.icon name="hero-clipboard-document" class="w-5 h-5" />
        </button>
      </div>
    </div>

    <div>
      <label class="block text-sm font-medium mb-3">Share to</label>
      <div class="grid grid-cols-4 gap-3">
        <.share_platform_link
          href={"https://twitter.com/intent/tweet?url=#{URI.encode(@profile_url)}&text=Check%20out%20#{@user.username}'s%20profile"}
          platform="twitter"
          bg_class="bg-black"
          label="X"
          title="Share on X"
          target="_blank"
          rel="noopener noreferrer"
        />
        <.share_platform_link
          href={"https://www.facebook.com/sharer/sharer.php?u=#{URI.encode(@profile_url)}"}
          platform="facebook"
          bg_class="bg-[#1877F2]"
          label="Facebook"
          title="Share on Facebook"
          target="_blank"
          rel="noopener noreferrer"
        />
        <.share_platform_link
          href={"https://www.linkedin.com/sharing/share-offsite/?url=#{URI.encode(@profile_url)}"}
          platform="linkedin"
          bg_class="bg-[#0A66C2]"
          label="LinkedIn"
          title="Share on LinkedIn"
          target="_blank"
          rel="noopener noreferrer"
        />
        <.share_platform_link
          href={"mailto:?subject=Check%20out%20#{@user.username}'s%20profile&body=#{URI.encode(@profile_url)}"}
          platform="email"
          bg_class="bg-gray-600"
          label="Email"
          title="Share via Email"
        />
      </div>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :platform, :string, required: true
  attr :bg_class, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :target, :string, default: nil
  attr :rel, :string, default: nil

  defp share_platform_link(assigns) do
    ~H"""
    <a
      href={@href}
      target={@target}
      rel={@rel}
      class="flex flex-col items-center gap-2 p-3 rounded-lg hover:bg-base-200 transition-colors"
      title={@title}
    >
      <div class={["w-12 h-12 rounded-full flex items-center justify-center text-white", @bg_class]}>
        {Phoenix.HTML.raw(Elektrine.Profiles.ProfileLink.get_platform_svg(@platform))}
      </div>
      <span class="text-xs">{@label}</span>
    </a>
    """
  end

  defp build_qr_code(profile_url) do
    try do
      profile_url
      |> EQRCode.encode()
      |> EQRCode.svg(width: 200, height: 200, background_color: "#ffffff", color: "#000000")
    rescue
      _ -> nil
    end
  end

  defp copy_button_attrs(true), do: [{"data-action", "copy-profile-url"}]

  defp copy_button_attrs(false) do
    [
      {"id", "copy-profile-url-btn"},
      {"phx-click", "copy_profile_url"},
      {"phx-hook", "CopyButton"}
    ]
  end
end
