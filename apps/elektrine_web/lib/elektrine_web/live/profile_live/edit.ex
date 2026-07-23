defmodule ElektrineWeb.ProfileLive.Edit do
  use ElektrineWeb, :live_view
  alias Elektrine.Accounts
  alias Elektrine.Constants
  alias Elektrine.Domains
  alias Elektrine.Profiles
  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Repo
  alias Elektrine.Security.SafeExternalURL
  alias Elektrine.StaticSites
  alias Elektrine.Theme
  alias ElektrineWeb.GitHubWebhooks
  alias ElektrineWeb.Platform.Integrations

  import ElektrineWeb.ProfileLive.DesignSections
  import ElektrineWeb.ProfileLive.DesignThemeSections
  import ElektrineWeb.ProfileLive.EffectsSections
  import ElektrineWeb.ProfileLive.EditSections

  @profile_tabs [
    {"profile", "hero-user", "Profile"},
    {"design", "hero-paint-brush", "Design"},
    {"effects", "hero-sparkles", "Effects"},
    {"content", "hero-squares-2x2", "Content"},
    {"publish", "hero-rocket-launch", "Publish"}
  ]
  @valid_tabs Enum.map(@profile_tabs, fn {tab, _icon, _label} -> tab end)
  @default_tab "profile"
  @tab_aliases %{
    "basic" => "profile",
    "appearance" => "design",
    "avatar" => "effects",
    "username" => "effects",
    "links" => "content",
    "widgets" => "content",
    "badges" => "content",
    "advanced" => "design",
    "static_site" => "publish"
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    profile = load_edit_profile(user.id)

    # Create default profile if none exists
    profile =
      if profile do
        profile
      else
        case Profiles.create_user_profile(user.id, %{
               display_name: user.username
             }) do
          {:ok, _new_profile} -> load_edit_profile(user.id)
          _ -> nil
        end
      end

    user_badges = Profiles.list_user_badges(user.id)

    # Get static site info
    static_site_files = StaticSites.list_files(user.id)
    static_site_storage = StaticSites.total_storage_used(user.id)
    github_connected_account = github_connected_account(user.id)
    static_site_deployment = StaticSites.get_static_site_deployment(user.id)
    static_site_deploys = StaticSites.list_static_site_deploys(static_site_deployment)

    # Admins get higher upload limits
    # 100MB vs 10MB
    background_limit = if user.is_admin, do: 100 * 1024 * 1024, else: 10 * 1024 * 1024
    # 10MB vs 1MB
    favicon_limit = if user.is_admin, do: 10 * 1024 * 1024, else: 1 * 1024 * 1024

    {:ok,
     socket
     |> assign(:page_title, "Customize Profile")
     |> assign(:user, user)
     |> assign(:profile, profile)
     |> assign(
       :static_site_url,
       Domains.profile_url_for_user(user) || "/#{user.handle || user.username}"
     )
     |> assign(:user_badges, user_badges)
     |> assign(:editing_link_id, nil)
     |> assign(:editing_link_data, %{})
     |> assign(:selected_platform, "custom")
     |> assign(:static_site_files, static_site_files)
     |> assign(:static_site_storage, static_site_storage)
     |> assign(:static_site_limit, user.storage_limit_bytes || 524_288_000)
     |> assign(:github_connected_account, github_connected_account)
     |> assign(:static_site_deployment, static_site_deployment)
     |> assign(:static_site_deploys, static_site_deploys)
     |> assign(:github_deploy_form, github_deploy_form(static_site_deployment))
     |> assign(:profile_save_status, "Saved")
     |> assign(:drag_over, false)
     |> assign(:editing_file, nil)
     |> assign(:file_content, nil)
     |> allow_upload(:background,
       accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm),
       max_entries: 1,
       max_file_size: background_limit
     )
     |> allow_upload(:favicon,
       accept: ~w(.png .ico .svg .jpg .jpeg),
       max_entries: 1,
       max_file_size: favicon_limit
     )
     |> allow_upload(:static_site,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: 100 * 1024 * 1024,
       auto_upload: true
     )
     |> allow_upload(:static_files,
       accept:
         ~w(.zip .html .htm .css .js .json .txt .png .jpg .jpeg .gif .webp .svg .ico .woff .woff2 .ttf .otf),
       max_entries: 20,
       max_file_size: 10 * 1024 * 1024,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _url, socket) do
    # Set tab from URL parameter
    {:noreply, assign(socket, :selected_tab, normalize_selected_tab(tab))}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Default to basic tab if no tab specified
    {:noreply, assign(socket, :selected_tab, @default_tab)}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    # Update URL with tab parameter so it persists on refresh
    {:noreply, push_patch(socket, to: ~p"/account/profile/edit?tab=#{tab}")}
  end

  @impl true
  def handle_event("validate_profile", %{"profile" => _profile_params}, socket) do
    {:noreply, assign(socket, :profile_save_status, "Unsaved changes")}
  end

  def handle_event("validate_background_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_background_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :background, ref)}
  end

  def handle_event("validate_favicon_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_favicon_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :favicon, ref)}
  end

  def handle_event("remove_favicon", _params, socket) do
    if socket.assigns.profile do
      case Profiles.update_user_profile(socket.assigns.profile, %{favicon_url: nil}) do
        {:ok, updated_profile} ->
          {:noreply,
           socket
           |> assign(:profile, updated_profile)
           |> notify_info("Favicon removed")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to remove favicon")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_background", _params, socket) do
    if socket.assigns.profile do
      case Profiles.update_user_profile(socket.assigns.profile, %{
             background_url: nil,
             background_type: "gradient"
           }) do
        {:ok, updated_profile} ->
          {:noreply,
           socket
           |> assign(:profile, updated_profile)
           |> notify_info("Background removed")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to remove background")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_platform", %{"platform" => platform}, socket) do
    {:noreply, assign(socket, :selected_platform, platform)}
  end

  def handle_event("select_edit_platform", %{"platform" => platform}, socket) do
    updated_data = Map.put(socket.assigns.editing_link_data, "platform", platform)
    {:noreply, assign(socket, :editing_link_data, updated_data)}
  end

  # Allowlist of valid profile color fields to prevent atom exhaustion DoS
  @valid_color_fields ~w(
    accent_color text_color background_color icon_color
    container_background_color pattern_color username_glow_color
    username_shadow_color tick_color
  )a
  @valid_color_field_names Enum.map(@valid_color_fields, &Atom.to_string/1)
  @valid_color_field_map Map.new(@valid_color_fields, &{Atom.to_string(&1), &1})
  @valid_effect_fields ~w(profile_opacity container_opacity pattern_opacity profile_blur)a
  @valid_effect_field_names Enum.map(@valid_effect_fields, &Atom.to_string/1)
  @valid_effect_field_map Map.new(@valid_effect_fields, &{Atom.to_string(&1), &1})
  @valid_username_color_fields ~w(username_glow_color username_shadow_color)a
  @valid_username_color_field_names Enum.map(@valid_username_color_fields, &Atom.to_string/1)
  @valid_username_color_field_map Map.new(
                                    @valid_username_color_fields,
                                    &{Atom.to_string(&1), &1}
                                  )

  def handle_event("update_color", %{"profile" => profile_params, "_target" => target}, socket) do
    if socket.assigns.profile do
      # Extract the field name from target (e.g., ["profile", "text_color"] -> "text_color")
      field_name = List.last(target)
      color = Map.get(profile_params, field_name)

      if color && field_name in @valid_color_field_names do
        field_atom = Map.fetch!(@valid_color_field_map, field_name)
        attrs = %{field_atom => color}

        case Profiles.update_user_profile(socket.assigns.profile, attrs) do
          {:ok, updated_profile} ->
            {:noreply, mark_profile_saved(socket, updated_profile)}

          {:error, _changeset} ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_effect", %{"profile" => profile_params, "_target" => target}, socket) do
    if socket.assigns.profile do
      # Extract the field name from target (e.g., ["profile", "profile_blur"] -> "profile_blur")
      field_name = List.last(target)
      value = Map.get(profile_params, field_name)

      if value && field_name in @valid_effect_field_names do
        field_atom = Map.fetch!(@valid_effect_field_map, field_name)

        case parse_effect_value(field_name, value) do
          {:ok, parsed_value} ->
            attrs = %{field_atom => parsed_value}

            case Profiles.update_user_profile(socket.assigns.profile, attrs) do
              {:ok, updated_profile} ->
                {:noreply, mark_profile_saved(socket, updated_profile)}

              {:error, _changeset} ->
                {:noreply, socket}
            end

          :error ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_username_effect", %{"profile" => profile_params}, socket) do
    if socket.assigns.profile do
      # Extract username effect and related settings
      attrs =
        %{
          username_effect: Map.get(profile_params, "username_effect"),
          username_glow_intensity:
            parse_username_intensity(Map.get(profile_params, "username_glow_intensity"))
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case Profiles.update_user_profile(socket.assigns.profile, attrs) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "update_username_color",
        %{"profile" => profile_params, "_target" => target},
        socket
      ) do
    if socket.assigns.profile do
      # Extract the field name from target (e.g., ["profile", "username_glow_color"] -> "username_glow_color")
      field_name = List.last(target)
      color = Map.get(profile_params, field_name)

      if color && field_name in @valid_username_color_field_names do
        field_atom = Map.fetch!(@valid_username_color_field_map, field_name)
        attrs = %{field_atom => color}

        case Profiles.update_user_profile(socket.assigns.profile, attrs) do
          {:ok, updated_profile} ->
            {:noreply, mark_profile_saved(socket, updated_profile)}

          {:error, _changeset} ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_font", %{"profile" => %{"font_family" => font_family}}, socket) do
    if socket.assigns.profile do
      # Convert empty string to nil for "System Default"
      font_value = Elektrine.Strings.present(font_family)

      case Profiles.update_user_profile(socket.assigns.profile, %{font_family: font_value}) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_cursor", %{"profile" => %{"cursor_style" => cursor_style}}, socket) do
    if socket.assigns.profile do
      case Profiles.update_user_profile(socket.assigns.profile, %{cursor_style: cursor_style}) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_link_style", %{"profile" => %{"link_display_style" => style}}, socket) do
    if socket.assigns.profile do
      case Profiles.update_user_profile(socket.assigns.profile, %{link_display_style: style}) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "update_link_effect",
        %{"profile" => %{"link_highlight_effect" => effect}},
        socket
      ) do
    if socket.assigns.profile do
      case Profiles.update_user_profile(socket.assigns.profile, %{link_highlight_effect: effect}) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_palette", %{"base_color" => base_color}, socket) do
    if socket.assigns.profile do
      # Generate harmonious color palette from base color
      palette = generate_color_palette(base_color)

      case Profiles.update_user_profile(socket.assigns.profile, palette) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, notify_error(socket, "Failed to update colors")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply_design_preset", %{"preset" => preset}, socket) do
    if socket.assigns.profile do
      case design_preset_attrs(preset) do
        nil ->
          {:noreply, socket}

        attrs ->
          case Profiles.update_user_profile(socket.assigns.profile, attrs) do
            {:ok, updated_profile} ->
              {:noreply, mark_profile_saved(socket, updated_profile)}

            {:error, _changeset} ->
              {:noreply, notify_error(socket, "Failed to apply preset")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reset_design_section", %{"section" => section}, socket) do
    if socket.assigns.profile do
      attrs = design_reset_attrs(section)

      case Profiles.update_user_profile(socket.assigns.profile, attrs) do
        {:ok, updated_profile} ->
          {:noreply, mark_profile_saved(socket, updated_profile)}

        {:error, _changeset} ->
          {:noreply, notify_error(socket, "Failed to reset design settings")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_link", %{"link" => link_params}, socket) do
    if socket.assigns.profile do
      # Check link limit
      current_count =
        if socket.assigns.profile.links, do: length(socket.assigns.profile.links), else: 0

      max_links = Constants.max_profile_links()

      if current_count >= max_links do
        {:noreply, notify_error(socket, "Maximum #{max_links} links allowed")}
      else
        # Ensure all keys are strings
        clean_params =
          for {key, value} <- link_params, into: %{} do
            {to_string(key), to_string(value)}
          end
          |> normalize_profile_link_params()

        # Fetch thumbnail automatically if URL is provided and no thumbnail yet
        clean_params =
          if clean_params["url"] && !Elektrine.Strings.present?(clean_params["thumbnail_url"]) do
            # Fetch metadata in background and get image
            Elektrine.Async.start(fn ->
              case fetch_link_thumbnail(clean_params["url"]) do
                {:ok, thumbnail_url} ->
                  # Update the link after creation
                  # Brief delay to let creation complete
                  :timer.sleep(100)
                  profile = load_edit_profile(socket.assigns.profile.user_id)

                  if profile && profile.links do
                    # Find the most recently created link
                    latest_link = Enum.max_by(profile.links, & &1.inserted_at)

                    if latest_link.url == clean_params["url"] do
                      Profiles.update_profile_link(latest_link, %{
                        "thumbnail_url" => thumbnail_url
                      })
                    end
                  end

                {:error, _} ->
                  :ok
              end
            end)

            clean_params
          else
            clean_params
          end

        case Profiles.create_profile_link(socket.assigns.profile.id, clean_params) do
          {:ok, _link} ->
            # Reload profile with updated links
            updated_profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> notify_info("Link added successfully!")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> notify_error("Failed to add link: #{inspect(changeset.errors)}")}
        end
      end
    else
      {:noreply,
       socket
       |> notify_error("Please create your profile first")}
    end
  end

  def handle_event("edit_link", %{"id" => link_id}, socket) do
    if socket.assigns.profile do
      link = find_profile_link(socket.assigns.profile, link_id)

      if link do
        {:noreply,
         socket
         |> assign(:editing_link_id, link.id)
         |> assign(:editing_link_data, %{
           "title" => link.title,
           "url" => link.url,
           "description" => link.description || "",
           "platform" => link.platform,
           "display_style" => link.display_style,
           "highlight_effect" => link.highlight_effect,
           "section" => link.section || "",
           "thumbnail_url" => link.thumbnail_url || "",
           "pinned" => link.pinned,
           "active_from" => format_datetime_local(link.active_from),
           "active_until" => format_datetime_local(link.active_until),
           "is_active" => link.is_active
         })}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_edit_link", %{"link" => link_params}, socket) do
    if socket.assigns.profile && socket.assigns.editing_link_id do
      link = Enum.find(socket.assigns.profile.links, &(&1.id == socket.assigns.editing_link_id))

      if link do
        # Ensure all keys are strings and handle checkbox
        clean_params =
          for {key, value} <- link_params, into: %{} do
            {to_string(key), to_string(value)}
          end
          |> convert_checkbox_to_boolean("is_active")
          |> convert_checkbox_to_boolean("pinned")
          |> normalize_profile_link_params()

        case Profiles.update_profile_link(link, clean_params) do
          {:ok, _updated_link} ->
            # Reload profile with updated links
            updated_profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> assign(:editing_link_id, nil)
             |> assign(:editing_link_data, %{})
             |> notify_info("Link updated successfully!")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> notify_error("Failed to update link: #{inspect(changeset.errors)}")}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit_link", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_link_id, nil)
     |> assign(:editing_link_data, %{})}
  end

  def handle_event("check_link_health", %{"id" => link_id}, socket) do
    link = socket.assigns.profile && find_profile_link(socket.assigns.profile, link_id)

    if link do
      {status, error} = check_profile_link_url(link.url)

      _ =
        Profiles.update_profile_link(link, %{
          "last_check_status" => status,
          "last_check_error" => error,
          "last_checked_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      updated_profile = load_edit_profile(socket.assigns.user.id)

      {:noreply,
       socket
       |> assign(:profile, updated_profile)
       |> notify_info(if(status == "ok", do: "Link check passed", else: "Link appears broken"))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_link", %{"id" => link_id}, socket) do
    # Find the link and delete it
    if socket.assigns.profile do
      link = find_profile_link(socket.assigns.profile, link_id)

      if link do
        case Profiles.delete_profile_link(link) do
          {:ok, _} ->
            # Reload profile with updated links
            updated_profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> notify_info("Link deleted successfully!")}

          {:error, _} ->
            {:noreply,
             socket
             |> notify_error("Failed to delete link")}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_widget", %{"widget" => widget_params}, socket) do
    if socket.assigns.profile do
      # Get current widget count for position
      current_count =
        if socket.assigns.profile.widgets, do: length(socket.assigns.profile.widgets), else: 0

      max_widgets = Constants.max_profile_widgets()

      if current_count >= max_widgets do
        {:noreply, notify_error(socket, "Maximum #{max_widgets} widgets allowed")}
      else
        # Transform widget content based on type
        widget_attrs =
          widget_params
          |> transform_widget_url()
          |> Map.put("profile_id", socket.assigns.profile.id)
          |> Map.put("position", current_count)

        case Profiles.create_widget(widget_attrs) do
          {:ok, _widget} ->
            # Reload profile with updated widgets
            updated_profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> notify_info("Widget added successfully!")}

          {:error, _changeset} ->
            {:noreply, notify_error(socket, "Failed to add widget")}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_widget", %{"id" => widget_id}, socket) do
    if socket.assigns.profile do
      widget = find_profile_widget(socket.assigns.profile, widget_id)

      if widget do
        case Profiles.delete_widget(widget.id) do
          {:ok, _} ->
            # Reload profile with updated widgets
            updated_profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket
             |> assign(:profile, updated_profile)
             |> notify_info("Widget deleted successfully!")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to delete widget")}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_badge_visibility", %{"badge_id" => badge_id}, socket) do
    badge =
      case parse_positive_int(badge_id) do
        {:ok, badge_id} -> Enum.find(socket.assigns.user_badges, &(&1.id == badge_id))
        :error -> nil
      end

    if badge do
      case Profiles.update_badge(badge, %{visible: !badge.visible}) do
        {:ok, _updated_badge} ->
          # Reload badges
          updated_badges = Profiles.list_user_badges(socket.assigns.user.id)

          {:noreply,
           socket
           |> assign(:user_badges, updated_badges)
           |> notify_info(if badge.visible, do: "Badge hidden", else: "Badge visible")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to update badge")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_link", %{"id" => link_id, "direction" => direction}, socket) do
    links = socket.assigns.profile.links

    link_index =
      case parse_positive_int(link_id) do
        {:ok, link_id} -> Enum.find_index(links, &(&1.id == link_id))
        :error -> nil
      end

    if link_index do
      new_index =
        case direction do
          "up" -> max(0, link_index - 1)
          "down" -> min(length(links) - 1, link_index + 1)
          _ -> link_index
        end

      if new_index != link_index do
        # Swap positions
        reordered_links =
          links
          |> List.delete_at(link_index)
          |> List.insert_at(new_index, Enum.at(links, link_index))

        # Update positions in database
        reordered_links
        |> Enum.with_index()
        |> Enum.each(fn {link, idx} ->
          Profiles.update_profile_link(link, %{"position" => idx})
        end)

        # Reload profile
        updated_profile = load_edit_profile(socket.assigns.user.id)
        {:noreply, assign(socket, :profile, updated_profile)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_links", %{"ids" => ids}, socket) when is_list(ids) do
    links = socket.assigns.profile && socket.assigns.profile.links

    if is_list(links) do
      link_ids = MapSet.new(Enum.map(links, &Integer.to_string(&1.id)))
      ordered_ids = Enum.filter(ids, &MapSet.member?(link_ids, to_string(&1)))

      if length(ordered_ids) == length(links) do
        links_by_id = Map.new(links, &{Integer.to_string(&1.id), &1})

        ordered_ids
        |> Enum.with_index()
        |> Enum.each(fn {id, idx} ->
          links_by_id
          |> Map.fetch!(id)
          |> Profiles.update_profile_link(%{"position" => idx})
        end)

        updated_profile = load_edit_profile(socket.assigns.user.id)
        {:noreply, assign(socket, :profile, updated_profile)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_links", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_widget", %{"id" => widget_id, "direction" => direction}, socket) do
    widgets = socket.assigns.profile.widgets

    widget_index =
      case parse_positive_int(widget_id) do
        {:ok, widget_id} -> Enum.find_index(widgets, &(&1.id == widget_id))
        :error -> nil
      end

    if widget_index do
      new_index =
        case direction do
          "up" -> max(0, widget_index - 1)
          "down" -> min(length(widgets) - 1, widget_index + 1)
          _ -> widget_index
        end

      if new_index != widget_index do
        # Swap positions
        reordered_widgets =
          widgets
          |> List.delete_at(widget_index)
          |> List.insert_at(new_index, Enum.at(widgets, widget_index))

        # Update positions in database
        reordered_widgets
        |> Enum.with_index()
        |> Enum.each(fn {widget, idx} ->
          Profiles.update_widget(widget, %{position: idx})
        end)

        # Reload profile
        updated_profile = load_edit_profile(socket.assigns.user.id)
        {:noreply, assign(socket, :profile, updated_profile)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_profile", params, socket) do
    if upload_in_progress?(socket, [:background, :favicon]) do
      {:noreply, notify_error(socket, "Wait for uploads to finish before saving")}
    else
      profile_params = params["profile"] || %{}

      # Handle background upload
      uploaded_backgrounds =
        consume_uploaded_entries(socket, :background, fn %{path: path}, entry ->
          user_id = socket.assigns.current_user.id

          upload_struct = %Plug.Upload{
            path: path,
            content_type: entry.client_type,
            filename: entry.client_name
          }

          case Elektrine.Uploads.upload_background(upload_struct, user_id) do
            {:ok, metadata} ->
              {:ok, metadata}

            {:error, _reason} ->
              {:postpone, :error}
          end
        end)

      # Add background URL and size to params if uploaded
      profile_params =
        case uploaded_backgrounds do
          [metadata | _] when is_map(metadata) ->
            url = metadata.key
            # Also ensure background_type is set based on upload
            profile_params
            |> Map.put("background_url", to_string(url))
            |> Map.put("background_size", metadata.size)
            |> then(fn params ->
              # If background_type not explicitly set, infer from URL
              if Map.get(params, "background_type") in [nil, "gradient", "solid"] do
                type = if String.match?(url, ~r/\.(mp4|webm)$/i), do: "video", else: "image"
                Map.put(params, "background_type", type)
              else
                params
              end
            end)

          _ ->
            profile_params
        end

      # Handle favicon upload
      uploaded_favicons =
        consume_uploaded_entries(socket, :favicon, fn %{path: path}, entry ->
          user_id = socket.assigns.current_user.id

          upload_struct = %Plug.Upload{
            path: path,
            content_type: entry.client_type,
            filename: entry.client_name
          }

          case Elektrine.Uploads.upload_favicon(upload_struct, user_id) do
            {:ok, metadata} ->
              {:ok, metadata}

            {:error, _reason} ->
              {:postpone, :error}
          end
        end)

      # Add favicon URL to params if uploaded
      profile_params =
        case uploaded_favicons do
          [metadata | _] when is_map(metadata) ->
            Map.put(profile_params, "favicon_url", to_string(metadata.key))

          _ ->
            profile_params
        end

      # Convert checkbox values to booleans - only for fields present in the form
      profile_params =
        profile_params
        |> transform_profile_visibility_controls()
        |> convert_checkbox_to_boolean_if_present("show_discord_presence")
        |> convert_checkbox_to_boolean_if_present("use_discord_avatar")
        |> convert_checkbox_to_boolean_if_present("hide_view_counter")
        |> convert_checkbox_to_boolean_if_present("hide_uid")
        |> convert_checkbox_to_boolean_if_present("hide_avatar")
        |> convert_checkbox_to_boolean_if_present("hide_timeline")
        |> convert_checkbox_to_boolean_if_present("hide_community_posts")
        |> convert_checkbox_to_boolean_if_present("hide_share_button")
        |> convert_checkbox_to_boolean_if_present("extend_layout")
        |> convert_checkbox_to_boolean_if_present("text_background")
        |> convert_checkbox_to_boolean_if_present("typewriter_effect")
        |> convert_checkbox_to_boolean_if_present("typewriter_title")
        |> convert_checkbox_to_boolean_if_present("pattern_animated")
        |> convert_checkbox_to_boolean_if_present("show_birthday")

      # Convert empty string font_family to nil for "System Default"
      profile_params =
        if Map.has_key?(profile_params, "font_family") &&
             not Elektrine.Strings.present?(profile_params["font_family"]) do
          Map.put(profile_params, "font_family", nil)
        else
          profile_params
        end

      # Birthday fields live on the user, not the profile
      {user_params, profile_params} =
        Map.split(profile_params, ["birthday", "show_birthday", "profile_visibility"])

      # Apply both writes atomically: a birthday validation error must not
      # drop the profile edits, and a failed profile upsert must not leave a
      # committed (and federated) user update behind. Side effects are safe
      # here: Accounts.update_user only fires username-history/mailbox/actor
      # federation side effects on username or avatar changes, which cannot
      # occur for birthday params, and Profiles federation only writes
      # activity/delivery rows, which roll back with the transaction.
      result =
        Repo.transaction(fn ->
          with {:ok, updated_user} <-
                 maybe_update_user_settings(socket.assigns.user, user_params),
               {:ok, _updated_profile} <-
                 Profiles.upsert_user_profile(socket.assigns.user.id, profile_params) do
            updated_user
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, updated_user} ->
          # Force reload profile with links
          refreshed_profile = load_edit_profile(socket.assigns.user.id)

          {:noreply,
           socket
           |> assign(:user, updated_user)
           |> assign(:current_user, updated_user)
           |> assign(:profile, refreshed_profile)
           |> assign(:profile_save_status, "Saved")
           |> push_event("profile_updated", %{})}

        {:error, changeset} ->
          error_msg = "Failed to update profile: #{inspect(changeset.errors)}"

          {:noreply,
           socket
           |> notify_error(error_msg)}
      end
    end
  end

  # Static Site Handlers

  def handle_event("update_github_deploy_form", %{"github_deploy" => params}, socket) do
    {:noreply, assign(socket, :github_deploy_form, normalize_github_deploy_form(params))}
  end

  def handle_event("save_github_deploy_link", %{"github_deploy" => params}, socket) do
    form = normalize_github_deploy_form(params)

    case github_repo_info(form) do
      %{owner: owner, repo: repo} ->
        attrs = %{
          repo_owner: owner,
          repo_name: repo,
          branch: form["branch"],
          site_dir: form["site_dir"],
          build_command: ""
        }

        case StaticSites.upsert_github_deployment(socket.assigns.user.id, attrs) do
          {:ok, deployment} ->
            {deployment, message} = maybe_install_github_webhook(deployment, socket)
            deploys = StaticSites.list_static_site_deploys(deployment)

            {:noreply,
             socket
             |> assign(:static_site_deployment, deployment)
             |> assign(:static_site_deploys, deploys)
             |> assign(:github_deploy_form, github_deploy_form(deployment))
             |> notify_info(message)}

          {:error, _changeset} ->
            {:noreply, notify_error(socket, "Could not link that GitHub repository")}
        end

      nil ->
        {:noreply, notify_error(socket, "Enter a GitHub repository like owner/repo")}
    end
  end

  def handle_event("deploy_static_site_from_github", _params, socket) do
    case socket.assigns.static_site_deployment do
      nil ->
        {:noreply, notify_error(socket, "Link a GitHub repository first")}

      deployment ->
        case StaticSites.enqueue_github_deploy(deployment) do
          {:ok, _job} ->
            deployment = StaticSites.get_static_site_deployment(socket.assigns.user.id)
            deploys = StaticSites.list_static_site_deploys(deployment)

            {:noreply,
             socket
             |> assign(:static_site_deployment, deployment)
             |> assign(:static_site_deploys, deploys)
             |> notify_info("Deploy queued")}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Could not queue deploy")}
        end
    end
  end

  def handle_event("rollback_static_site_deploy", %{"id" => deploy_id}, socket) do
    with {:ok, id} <- parse_positive_int(deploy_id),
         deploy when not is_nil(deploy) <-
           StaticSites.get_static_site_deploy_for_user(socket.assigns.user.id, id),
         {:ok, %{deployment: deployment}} <-
           StaticSites.rollback_static_site(socket.assigns.user, deploy) do
      static_site_files = StaticSites.list_files(socket.assigns.user.id)
      static_site_storage = StaticSites.total_storage_used(socket.assigns.user.id)
      deploys = StaticSites.list_static_site_deploys(deployment)

      {:noreply,
       socket
       |> assign(:static_site_deployment, deployment)
       |> assign(:static_site_deploys, deploys)
       |> assign(:static_site_files, static_site_files)
       |> assign(:static_site_storage, static_site_storage)
       |> notify_info("Rollback complete")}
    else
      _ ->
        {:noreply, notify_error(socket, "Could not rollback to that deploy")}
    end
  end

  def handle_event("set_profile_mode", %{"mode" => mode}, socket) do
    case mode do
      "static" ->
        case StaticSites.enable_static_mode(socket.assigns.user.id) do
          {:ok, _} ->
            profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket |> assign(:profile, profile) |> notify_info("Static site mode enabled")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to enable static mode")}
        end

      "builder" ->
        case StaticSites.enable_builder_mode(socket.assigns.user.id) do
          {:ok, _} ->
            profile = load_edit_profile(socket.assigns.user.id)

            {:noreply,
             socket |> assign(:profile, profile) |> notify_info("Profile builder mode enabled")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to enable builder mode")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_static_site_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_static_site_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :static_site, ref)}
  end

  def handle_event("upload_static_site", _params, socket) do
    if upload_in_progress?(socket, [:static_site]) do
      {:noreply, notify_error(socket, "Wait for the site upload to finish before publishing")}
    else
      user = socket.assigns.user
      require Logger
      Logger.info("Static site upload started for user #{user.id}")

      uploaded_files =
        consume_uploaded_entries(socket, :static_site, fn %{path: path}, entry ->
          Logger.info("Processing uploaded file: #{entry.client_name}")
          # Read the zip file and upload to storage
          case File.read(path) do
            {:ok, zip_binary} ->
              Logger.info("Read zip file, size: #{byte_size(zip_binary)} bytes")

              case StaticSites.upload_zip(user, zip_binary) do
                {:ok, count} ->
                  Logger.info("Successfully uploaded #{count} files")
                  {:ok, {:success, count}}

                {:error, :partial_upload, errors} ->
                  Logger.error("Partial upload, errors: #{inspect(errors)}")
                  {:ok, {:error, :partial_upload}}

                {:error, reason} ->
                  Logger.error("Upload failed: #{inspect(reason)}")
                  {:ok, {:error, reason}}
              end

            {:error, reason} ->
              Logger.error("Failed to read file: #{inspect(reason)}")
              {:ok, {:error, reason}}
          end
        end)

      Logger.info("Upload results: #{inspect(uploaded_files)}")

      case uploaded_files do
        [{:success, count}] ->
          static_site_files = StaticSites.list_files(user.id)
          static_site_storage = StaticSites.total_storage_used(user.id)
          profile = ensure_static_profile_mode(user.id)

          {:noreply,
           socket
           |> assign(:profile, profile)
           |> assign(:static_site_files, static_site_files)
           |> assign(:static_site_storage, static_site_storage)
           |> notify_info("Site published. Uploaded #{count} files successfully")}

        [{:error, :storage_limit_exceeded}] ->
          {:noreply, notify_error(socket, "Storage limit exceeded")}

        [{:error, :file_limit_exceeded}] ->
          {:noreply, notify_error(socket, "File limit exceeded (1000 files max)")}

        [{:error, {:upload_failed, reason}}] ->
          {:noreply, notify_error(socket, "Storage backend error: #{inspect(reason)}")}

        [{:error, :partial_upload}] ->
          {:noreply, notify_error(socket, "Only part of the site uploaded")}

        [{:error, _reason}] ->
          {:noreply, notify_error(socket, "Failed to upload static site")}

        [] ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("delete_static_file", %{"path" => path}, socket) do
    case StaticSites.delete_file(socket.assigns.user.id, path) do
      {:ok, _} ->
        static_site_files = StaticSites.list_files(socket.assigns.user.id)
        static_site_storage = StaticSites.total_storage_used(socket.assigns.user.id)

        {:noreply,
         socket
         |> assign(:static_site_files, static_site_files)
         |> assign(:static_site_storage, static_site_storage)
         |> notify_info("File deleted")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to delete file")}
    end
  end

  def handle_event("delete_all_static_files", _params, socket) do
    StaticSites.delete_all_files(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(:static_site_files, [])
     |> assign(:static_site_storage, 0)
     |> notify_info("All static site files deleted")}
  end

  # Individual file upload handlers
  def handle_event("validate_static_files", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_static_file_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :static_files, ref)}
  end

  def handle_event("upload_static_files", _params, socket) do
    if upload_in_progress?(socket, [:static_files]) do
      {:noreply, notify_error(socket, "Wait for file uploads to finish before publishing")}
    else
      user = socket.assigns.user

      upload_results =
        consume_uploaded_entries(socket, :static_files, fn %{path: path}, entry ->
          case File.read(path) do
            {:ok, binary} ->
              if String.ends_with?(String.downcase(entry.client_name || ""), ".zip") do
                case StaticSites.upload_zip(user, binary) do
                  {:ok, count} -> {:ok, {:ok, count}}
                  {:error, reason} -> {:ok, {:error, reason}}
                  {:error, :partial_upload, errors} -> {:ok, {:error, {:partial_upload, errors}}}
                end
              else
                file_path = entry.client_name
                content_type = entry.client_type || MIME.from_path(file_path)

                case StaticSites.upload_file(user, file_path, binary, content_type) do
                  {:ok, _file} -> {:ok, {:ok, 1}}
                  {:error, reason} -> {:ok, {:error, reason}}
                end
              end

            {:error, reason} ->
              {:ok, {:error, reason}}
          end
        end)

      success_count =
        Enum.reduce(upload_results, 0, fn
          {:ok, count}, acc when is_integer(count) -> acc + count
          _, acc -> acc
        end)

      error_count = Enum.count(upload_results, &match?({:error, _}, &1))

      static_site_files = StaticSites.list_files(user.id)
      static_site_storage = StaticSites.total_storage_used(user.id)

      profile =
        if success_count > 0,
          do: ensure_static_profile_mode(user.id),
          else: socket.assigns.profile

      socket =
        socket
        |> assign(:profile, profile)
        |> assign(:static_site_files, static_site_files)
        |> assign(:static_site_storage, static_site_storage)

      cond do
        success_count > 0 and error_count == 0 ->
          {:noreply, notify_info(socket, "Site updated. Uploaded #{success_count} file(s)")}

        success_count > 0 and error_count > 0 ->
          {:noreply,
           notify_info(
             socket,
             "Site updated. Uploaded #{success_count} file(s), #{error_count} failed"
           )}

        true ->
          {:noreply, notify_error(socket, "Failed to upload files")}
      end
    end
  end

  # Drag and drop events
  def handle_event("dragover", _params, socket) do
    {:noreply, assign(socket, :drag_over, true)}
  end

  def handle_event("dragleave", _params, socket) do
    {:noreply, assign(socket, :drag_over, false)}
  end

  def handle_event("drop", _params, socket) do
    {:noreply, assign(socket, :drag_over, false)}
  end

  # Code editor handlers
  def handle_event("edit_file", %{"path" => path}, socket) do
    user = socket.assigns.user

    case StaticSites.get_file(user.id, path) do
      nil ->
        {:noreply, notify_error(socket, "File not found")}

      file ->
        case StaticSites.get_file_content(file) do
          {:ok, content} ->
            {:noreply,
             socket
             |> assign(:editing_file, file)
             |> assign(:file_content, content)}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to load file content")}
        end
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_file, nil)
     |> assign(:file_content, nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    user = socket.assigns.user
    file = socket.assigns.editing_file

    if file do
      case StaticSites.upload_file(user, file.path, content, file.content_type) do
        {:ok, _updated_file} ->
          static_site_files = StaticSites.list_files(user.id)
          static_site_storage = StaticSites.total_storage_used(user.id)

          {:noreply,
           socket
           |> assign(:static_site_files, static_site_files)
           |> assign(:static_site_storage, static_site_storage)
           |> assign(:editing_file, nil)
           |> assign(:file_content, nil)
           |> notify_info("File saved")}

        {:error, _reason} ->
          {:noreply, notify_error(socket, "Failed to save file")}
      end
    else
      {:noreply, notify_error(socket, "No file selected")}
    end
  end

  def handle_event("create_file", %{"path" => path, "content" => content}, socket) do
    user = socket.assigns.user
    content_type = MIME.from_path(path)

    case StaticSites.upload_file(user, path, content, content_type) do
      {:ok, _file} ->
        static_site_files = StaticSites.list_files(user.id)
        static_site_storage = StaticSites.total_storage_used(user.id)

        {:noreply,
         socket
         |> assign(:static_site_files, static_site_files)
         |> assign(:static_site_storage, static_site_storage)
         |> notify_info("File created")}

      {:error, :invalid_file_type} ->
        {:noreply, notify_error(socket, "Invalid file type")}

      {:error, _reason} ->
        {:noreply, notify_error(socket, "Failed to create file")}
    end
  end

  defp maybe_update_user_settings(user, user_params) when map_size(user_params) == 0 do
    {:ok, user}
  end

  defp maybe_update_user_settings(user, user_params) do
    Accounts.update_user(user, user_params)
  end

  defp load_edit_profile(user_id), do: Profiles.get_user_profile(user_id, links: :all)

  defp upload_in_progress?(socket, upload_names) when is_list(upload_names) do
    Enum.any?(upload_names, &upload_in_progress?(socket, &1))
  end

  defp upload_in_progress?(socket, upload_name) when is_atom(upload_name) do
    {_completed, in_progress} = uploaded_entries(socket, upload_name)
    in_progress != []
  end

  defp ensure_static_profile_mode(user_id) do
    _ = StaticSites.enable_static_mode(user_id)
    load_edit_profile(user_id)
  end

  # Helper functions for username intensity parsing
  defp parse_username_intensity(nil), do: nil

  defp parse_username_intensity(value) when is_binary(value) do
    case Integer.parse(value) do
      {intensity, ""} -> intensity
      _ -> nil
    end
  end

  defp parse_username_intensity(value), do: value

  defp parse_effect_value(field_name, value)
       when field_name in ["profile_opacity", "container_opacity", "pattern_opacity"] do
    parse_float_value(value)
  end

  defp parse_effect_value("profile_blur", value), do: parse_integer_value(value)
  defp parse_effect_value(_field_name, _value), do: :error

  defp parse_float_value(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  defp parse_float_value(value) when is_integer(value), do: {:ok, value / 1.0}
  defp parse_float_value(value) when is_float(value), do: {:ok, value}
  defp parse_float_value(_value), do: :error

  defp parse_integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_integer_value(value) when is_integer(value), do: {:ok, value}
  defp parse_integer_value(_value), do: :error

  # Helper function to fetch link thumbnail
  defp fetch_link_thumbnail(url) do
    case Integrations.social_link_preview_metadata(url) do
      %{image_url: image_url, status: "success"} when not is_nil(image_url) ->
        {:ok, image_url}

      %{favicon_url: favicon_url, status: "success"} when not is_nil(favicon_url) ->
        {:ok, favicon_url}

      _ ->
        {:error, :no_image}
    end
  end

  # Helper functions for color palette generation
  defp generate_color_palette(base_color) do
    # Generate complementary colors
    %{
      accent_color: base_color,
      text_color: UserProfile.default(:text_color),
      # Much darker version for page background
      background_color: darken_color(base_color, 0.8),
      # Slightly lighter than page for container
      container_background_color: darken_color(base_color, 0.7),
      # Slightly lighter
      icon_color: lighten_color(base_color, 0.2),
      username_glow_color: base_color,
      username_gradient_from: base_color,
      # Complementary color
      username_gradient_to: shift_hue(base_color, 60)
    }
  end

  defp hex_to_rgb(hex), do: Theme.hex_to_rgb(hex)

  defp rgb_to_hex(r, g, b) do
    r = min(255, max(0, round(r)))
    g = min(255, max(0, round(g)))
    b = min(255, max(0, round(b)))

    "#" <>
      String.pad_leading(Integer.to_string(r, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(g, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(b, 16), 2, "0")
  end

  defp darken_color(hex, factor) do
    Theme.darken(hex, factor)
  end

  defp lighten_color(hex, factor) do
    Theme.lighten(hex, factor)
  end

  def badge_preview_style(badge_color, accent_color \\ nil) do
    badge_color = badge_color || UserProfile.default(:accent_color)
    accent_color = accent_color || badge_color

    {from_color, to_color} = Theme.gradient_pair(badge_color)

    "background: linear-gradient(to right, #{from_color}, #{to_color}); box-shadow: 0 2px 8px #{Theme.rgba(badge_color, 0.38)}, 0 1px 3px #{Theme.rgba(Theme.dark_text_color(), 0.5)}; border: 1px solid #{Theme.rgba(accent_color, 0.25)};"
  end

  defp shift_hue(hex, degrees) do
    {r, g, b} = hex_to_rgb(hex)

    # Convert RGB to HSL
    {h, s, l} = rgb_to_hsl(r, g, b)

    # Shift hue and wrap around 0-360
    new_h = :math.fmod(h + degrees, 360)
    new_h = if new_h < 0, do: new_h + 360, else: new_h

    # Convert back to RGB
    {new_r, new_g, new_b} = hsl_to_rgb(new_h, s, l)

    rgb_to_hex(new_r, new_g, new_b)
  end

  defp rgb_to_hsl(r, g, b) do
    r = r / 255.0
    g = g / 255.0
    b = b / 255.0

    max_c = max(max(r, g), b)
    min_c = min(min(r, g), b)
    delta = max_c - min_c

    l = (max_c + min_c) / 2.0

    s = if delta == 0, do: 0.0, else: delta / (1 - abs(2 * l - 1))

    h =
      cond do
        delta == 0 -> 0.0
        max_c == r -> 60 * :math.fmod((g - b) / delta, 6)
        max_c == g -> 60 * ((b - r) / delta + 2)
        max_c == b -> 60 * ((r - g) / delta + 4)
      end

    h = if h < 0, do: h + 360, else: h

    {h, s, l}
  end

  defp hsl_to_rgb(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    h_prime = h / 60.0
    x = c * (1 - abs(:math.fmod(h_prime, 2) - 1))
    m = l - c / 2

    {r1, g1, b1} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    {(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255}
  end

  # Helper functions for widget URL transformation
  defp transform_widget_url(%{"widget_type" => "youtube", "content" => content} = params) do
    # Transform YouTube URLs to embed format
    embed_url =
      cond do
        # Already an embed URL
        String.contains?(content, "youtube.com/embed/") or
            String.contains?(content, "youtube-nocookie.com/embed/") ->
          content

        # Standard watch URL: https://www.youtube.com/watch?v=VIDEO_ID
        String.contains?(content, "youtube.com/watch?v=") ->
          video_id =
            content |> String.split("v=") |> List.last() |> String.split("&") |> List.first()

          "https://www.youtube-nocookie.com/embed/#{video_id}"

        # Short URL: https://youtu.be/VIDEO_ID
        String.contains?(content, "youtu.be/") ->
          video_id =
            content
            |> String.split("youtu.be/")
            |> List.last()
            |> String.split("?")
            |> List.first()

          "https://www.youtube-nocookie.com/embed/#{video_id}"

        # Mobile URL: https://m.youtube.com/watch?v=VIDEO_ID
        String.contains?(content, "m.youtube.com/watch?v=") ->
          video_id =
            content |> String.split("v=") |> List.last() |> String.split("&") |> List.first()

          "https://www.youtube-nocookie.com/embed/#{video_id}"

        true ->
          content
      end

    Map.put(params, "content", embed_url)
  end

  defp transform_widget_url(%{"widget_type" => "spotify", "content" => content} = params) do
    # Transform Spotify URLs to embed format
    embed_url =
      cond do
        # Already an embed URL
        String.contains?(content, "open.spotify.com/embed/") ->
          content

        # Track URL: https://open.spotify.com/track/TRACK_ID
        String.contains?(content, "open.spotify.com/track/") ->
          track_id =
            content |> String.split("/track/") |> List.last() |> String.split("?") |> List.first()

          "https://open.spotify.com/embed/track/#{track_id}"

        # Album URL
        String.contains?(content, "open.spotify.com/album/") ->
          album_id =
            content |> String.split("/album/") |> List.last() |> String.split("?") |> List.first()

          "https://open.spotify.com/embed/album/#{album_id}"

        # Playlist URL
        String.contains?(content, "open.spotify.com/playlist/") ->
          playlist_id =
            content
            |> String.split("/playlist/")
            |> List.last()
            |> String.split("?")
            |> List.first()

          "https://open.spotify.com/embed/playlist/#{playlist_id}"

        true ->
          content
      end

    Map.put(params, "content", embed_url)
  end

  defp transform_widget_url(%{"widget_type" => "github_stats", "content" => content} = params) do
    # Sanitize GitHub username - only allow alphanumeric, hyphens
    sanitized =
      content
      |> String.trim()
      |> String.replace(~r/[^a-zA-Z0-9\-]/, "")
      # GitHub username max length
      |> String.slice(0, 39)

    Map.put(params, "content", sanitized)
  end

  defp transform_widget_url(%{"widget_type" => "discord_status", "content" => content} = params) do
    # Sanitize Discord ID - only allow numeric
    sanitized =
      content
      |> String.trim()
      |> String.replace(~r/[^0-9]/, "")
      # Discord ID max length
      |> String.slice(0, 20)

    Map.put(params, "content", sanitized)
  end

  defp transform_widget_url(%{"widget_type" => "image", "content" => content} = params) do
    # Validate image URL - must be https
    sanitized =
      if String.match?(
           content,
           ~r/^https:\/\/[^\s<>"]+\.(jpg|jpeg|png|gif|webp|svg)(\?[^\s<>"]*)?$/i
         ) do
        content
      else
        ""
      end

    Map.put(params, "content", sanitized)
  end

  defp transform_widget_url(params), do: params

  defp transform_profile_visibility_controls(params) do
    params
    |> put_hidden_flag_from_visibility("timeline_visibility", "hide_timeline")
    |> put_hidden_flag_from_visibility("community_posts_visibility", "hide_community_posts")
    |> put_hidden_flag_from_visibility("share_visibility", "hide_share_button")
    |> put_hidden_flag_from_visibility("identity_visibility", "hide_avatar")
    |> put_hidden_flag_from_visibility("view_counter_visibility", "hide_view_counter")
    |> put_hidden_flag_from_visibility("uid_visibility", "hide_uid")
    |> put_boolean_from_choice("layout_height", "extend_layout", "extended")
    |> Map.drop([
      "timeline_visibility",
      "community_posts_visibility",
      "share_visibility",
      "identity_visibility",
      "view_counter_visibility",
      "uid_visibility",
      "layout_height"
    ])
  end

  defp duplicate_profile_link_urls(profile) do
    profile
    |> Map.get(:links, [])
    |> Enum.map(&normalize_duplicate_link_url(Map.get(&1, :url)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.filter(fn {_url, count} -> count > 1 end)
    |> Enum.map(fn {url, _count} -> url end)
  end

  defp duplicate_profile_link_url?(profile, link) do
    normalized_url = normalize_duplicate_link_url(Map.get(link, :url))

    normalized_url != "" and normalized_url in duplicate_profile_link_urls(profile)
  end

  defp normalize_duplicate_link_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing("/")
  end

  defp normalize_duplicate_link_url(_url), do: ""

  defp normalize_profile_link_params(params) do
    params
    |> normalize_link_datetime_param("active_from")
    |> normalize_link_datetime_param("active_until")
  end

  defp normalize_link_datetime_param(params, field) do
    case Map.get(params, field) do
      value when value in [nil, ""] ->
        Map.put(params, field, nil)

      value when is_binary(value) ->
        case NaiveDateTime.from_iso8601(normalize_datetime_local_value(value)) do
          {:ok, naive} -> Map.put(params, field, DateTime.from_naive!(naive, "Etc/UTC"))
          {:error, _} -> Map.put(params, field, nil)
        end

      _ ->
        params
    end
  end

  defp normalize_datetime_local_value(value) do
    if String.length(value) == 16, do: value <> ":00", else: value
  end

  defp format_datetime_local(nil), do: ""

  defp format_datetime_local(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp format_datetime_local(_datetime), do: ""

  defp check_profile_link_url("mailto:" <> _address), do: {"ok", nil}
  defp check_profile_link_url("tel:" <> _phone), do: {"ok", nil}

  defp check_profile_link_url(url) when is_binary(url) do
    with {:ok, safe_url} <- SafeExternalURL.normalize(url),
         {:ok, response} <- Req.head(safe_url, redirect: true, receive_timeout: 5_000) do
      if response.status < 400 do
        {"ok", nil}
      else
        {"broken", "HTTP #{response.status}"}
      end
    else
      {:error, reason} -> {"broken", inspect(reason)}
      _ -> {"broken", "Request failed"}
    end
  rescue
    error -> {"broken", Exception.message(error)}
  end

  defp check_profile_link_url(_url), do: {"broken", "Invalid URL"}

  defp put_hidden_flag_from_visibility(params, source_field, target_field) do
    case Map.get(params, source_field) do
      "hidden" -> Map.put(params, target_field, true)
      "public" -> Map.put(params, target_field, false)
      _ -> params
    end
  end

  defp put_boolean_from_choice(params, source_field, target_field, truthy_value) do
    case Map.get(params, source_field) do
      ^truthy_value -> Map.put(params, target_field, true)
      value when is_binary(value) -> Map.put(params, target_field, false)
      _ -> params
    end
  end

  # Convert HTML checkbox values to booleans
  defp convert_checkbox_to_boolean(params, field_name) do
    case Map.get(params, field_name) do
      # Checkbox checked
      "true" -> Map.put(params, field_name, true)
      # Alternative checkbox value
      "on" -> Map.put(params, field_name, true)
      # Hidden input default
      "false" -> Map.put(params, field_name, false)
      # No value sent
      nil -> Map.put(params, field_name, false)
      # Already boolean
      true -> params
      # Already boolean
      false -> params
      _ -> Map.put(params, field_name, false)
    end
  end

  # Only convert checkbox if field is present in params (prevents overwriting other form sections)
  defp convert_checkbox_to_boolean_if_present(params, field_name) do
    if Map.has_key?(params, field_name) or Map.has_key?(params, "#{field_name}") do
      convert_checkbox_to_boolean(params, field_name)
    else
      # Don't modify if field not present
      params
    end
  end

  # Helper functions for platform placeholders
  defp get_title_placeholder(platform) do
    case platform do
      "twitter" -> "Twitter"
      "instagram" -> "Instagram"
      "github" -> "GitHub"
      "linkedin" -> "LinkedIn"
      "youtube" -> "YouTube"
      "tiktok" -> "TikTok"
      "discord" -> "Discord"
      "spotify" -> "Spotify"
      "email" -> "Email"
      "website" -> "Website"
      "reddit" -> "Reddit"
      "telegram" -> "Telegram"
      "soundcloud" -> "SoundCloud"
      "paypal" -> "PayPal"
      "adobe" -> "Adobe"
      "vk" -> "VK"
      "threads" -> "Threads"
      "twitch" -> "Twitch"
      "pinterest" -> "Pinterest"
      "behance" -> "Behance"
      "steam" -> "Steam"
      "bitcoin" -> "Bitcoin"
      "ethereum" -> "Ethereum"
      "gitlab" -> "GitLab"
      "facebook" -> "Facebook"
      "whatsapp" -> "WhatsApp"
      "mastodon" -> "Mastodon"
      _ -> "Title"
    end
  end

  defp get_url_placeholder(platform) do
    case platform do
      "twitter" -> "twitter.com/username"
      "instagram" -> "instagram.com/username"
      "github" -> "github.com/username"
      "linkedin" -> "linkedin.com/in/username"
      "youtube" -> "youtube.com/@channel"
      "tiktok" -> "tiktok.com/@username"
      "discord" -> "discord.gg/invite"
      "spotify" -> "spotify.com/artist"
      "email" -> "email@example.com"
      "website" -> "example.com"
      "reddit" -> "reddit.com/u/username"
      "telegram" -> "t.me/username"
      "soundcloud" -> "soundcloud.com/username"
      "paypal" -> "paypal.me/username"
      "adobe" -> "behance.net/username"
      "vk" -> "vk.com/username"
      "threads" -> "threads.net/@username"
      "twitch" -> "twitch.tv/username"
      "pinterest" -> "pinterest.com/username"
      "behance" -> "behance.net/username"
      "steam" -> "steamcommunity.com/id/username"
      "bitcoin" -> "Bitcoin address"
      "ethereum" -> "Ethereum address"
      "gitlab" -> "gitlab.com/username"
      "facebook" -> "facebook.com/username"
      "whatsapp" -> "wa.me/number"
      "mastodon" -> "mastodon.social/@username"
      _ -> "URL"
    end
  end

  defp github_connected_account(user_id) do
    user_id
    |> Accounts.list_connected_accounts()
    |> Enum.find(&(&1.provider == "github"))
  end

  defp github_oauth_configured? do
    present_env?("GITHUB_OAUTH_CLIENT_ID") and present_env?("GITHUB_OAUTH_CLIENT_SECRET")
  end

  defp github_static_deploy_ready?(nil), do: false

  defp github_static_deploy_ready?(account) do
    token = get_in(account.metadata || %{}, ["access_token"])
    scopes = account.scopes || []

    is_binary(token) and token != "" and "admin:repo_hook" in scopes
  end

  defp present_env?(name) do
    name
    |> System.get_env()
    |> case do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp default_github_deploy_form do
    %{
      "repo_url" => "",
      "branch" => "main",
      "site_dir" => "auto"
    }
  end

  defp github_deploy_form(nil), do: default_github_deploy_form()

  defp github_deploy_form(deployment) do
    default_github_deploy_form()
    |> Map.merge(%{
      "repo_url" => "#{deployment.repo_owner}/#{deployment.repo_name}",
      "branch" => deployment.branch,
      "site_dir" => deployment.site_dir
    })
  end

  defp deploy_status_badge_class("deployed"), do: "badge-success"
  defp deploy_status_badge_class("failed"), do: "badge-error"
  defp deploy_status_badge_class("rolled_back"), do: "badge-info"

  defp deploy_status_badge_class(status) when status in ["queued", "deploying"],
    do: "badge-warning"

  defp deploy_status_badge_class(_status), do: "badge-ghost"

  defp deploy_timeline_steps(deployment) do
    status = deployment.deploy_status || "idle"

    [
      %{
        label: "Repository linked",
        meta: "#{deployment.repo_owner}/#{deployment.repo_name}",
        state: :done
      },
      %{
        label: "Build queued",
        meta:
          if(status == "idle",
            do: "Waiting for push or manual deploy",
            else: "Deploy request accepted"
          ),
        state: deploy_step_state(status, ["queued", "deploying", "deployed", "failed"])
      },
      %{
        label: "Static files built",
        meta: site_dir_label(deployment.site_dir),
        state: deploy_step_state(status, ["deploying", "deployed", "failed"])
      },
      %{
        label: "Published",
        meta: "Profile URL updated after successful deploy",
        state: deploy_step_state(status, ["deployed"])
      }
    ]
  end

  defp deploy_step_state("failed", statuses) do
    if "failed" in statuses, do: :failed, else: :done
  end

  defp deploy_step_state(status, statuses) do
    cond do
      status == "deployed" -> :done
      status in statuses -> :active
      true -> :waiting
    end
  end

  defp deploy_step_dot_class(:done), do: "bg-success text-success-content"
  defp deploy_step_dot_class(:active), do: "bg-warning text-warning-content"
  defp deploy_step_dot_class(:failed), do: "bg-error text-error-content"
  defp deploy_step_dot_class(:waiting), do: "bg-base-300 text-base-content/60"

  defp deploy_step_icon(:done), do: "hero-check"
  defp deploy_step_icon(:failed), do: "hero-x-mark"
  defp deploy_step_icon(_state), do: "hero-clock"

  defp format_profile_datetime(nil), do: "Never"

  defp format_profile_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp format_profile_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp format_profile_datetime(datetime), do: to_string(datetime)

  defp link_health_badge_class("ok"), do: "badge-success"
  defp link_health_badge_class("broken"), do: "badge-error"
  defp link_health_badge_class(_status), do: "badge-ghost"

  defp link_ctr(%{clicks: clicks, impressions: impressions})
       when is_integer(clicks) and is_integer(impressions) and impressions > 0 do
    "#{Float.round(clicks / impressions * 100, 1)}%"
  end

  defp link_ctr(_link), do: "0%"

  defp link_schedule_label(link) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cond do
      link.active_from && DateTime.compare(link.active_from, now) == :gt ->
        "Scheduled"

      link.active_until && DateTime.compare(link.active_until, now) != :gt ->
        "Expired"

      link.active_from || link.active_until ->
        "Timed"

      true ->
        nil
    end
  end

  defp site_dir_label(nil), do: "Auto-detect output directory"
  defp site_dir_label(""), do: "Auto-detect output directory"
  defp site_dir_label("auto"), do: "Auto-detect output directory"
  defp site_dir_label(site_dir), do: "Publishing #{site_dir}"

  defp normalize_github_deploy_form(params) when is_map(params) do
    defaults = default_github_deploy_form()

    defaults
    |> Map.merge(%{
      "repo_url" => params |> Map.get("repo_url", defaults["repo_url"]) |> trim_string(),
      "branch" => params |> Map.get("branch", defaults["branch"]) |> normalize_branch(),
      "site_dir" => params |> Map.get("site_dir", defaults["site_dir"]) |> normalize_site_dir()
    })
  end

  defp normalize_github_deploy_form(_params), do: default_github_deploy_form()

  defp github_repo_info(%{"repo_url" => repo_url}), do: parse_github_repo(repo_url)
  defp github_repo_info(_form), do: nil

  defp maybe_install_github_webhook(deployment, socket) do
    with %{} = account <- socket.assigns.github_connected_account,
         true <- github_static_deploy_ready?(account),
         token when is_binary(token) <- get_in(account.metadata || %{}, ["access_token"]),
         {:ok, webhook_id} <-
           GitHubWebhooks.ensure_push_webhook(
             token,
             deployment.repo_owner,
             deployment.repo_name,
             github_webhook_url(),
             deployment.webhook_secret
           ) do
      deployment = maybe_store_webhook_id(deployment, webhook_id)
      {deployment, "Repository linked"}
    else
      _ -> {deployment, "Repository linked"}
    end
  end

  defp maybe_store_webhook_id(deployment, nil), do: deployment

  defp maybe_store_webhook_id(deployment, webhook_id) do
    case StaticSites.update_deployment_webhook(deployment, webhook_id) do
      {:ok, deployment} -> deployment
      {:error, _changeset} -> deployment
    end
  end

  defp github_webhook_url do
    ElektrineWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/ext/v1/static-site/deploy/github/webhook")
  end

  defp parse_github_repo(repo_url) when is_binary(repo_url) do
    trimmed = String.trim(repo_url)

    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/, trimmed) do
      [owner, repo] = String.split(trimmed, "/", parts: 2)
      %{owner: owner, repo: String.replace_suffix(repo, ".git", "")}
    else
      case URI.parse(trimmed) do
        %URI{host: host, path: path} when host in ["github.com", "www.github.com"] ->
          case path |> String.trim_leading("/") |> String.split("/", parts: 3) do
            [owner, repo | _] when owner != "" and repo != "" ->
              %{owner: owner, repo: String.replace_suffix(repo, ".git", "")}

            _ ->
              nil
          end

        _ ->
          nil
      end
    end
  end

  defp parse_github_repo(_repo_url), do: nil

  defp normalize_branch(value) do
    value = trim_string(value)

    if valid_github_branch_path?(value) do
      value
    else
      "main"
    end
  end

  defp valid_github_branch_path?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, value) and value != "" and
      valid_github_branch_segments?(value)
  end

  defp valid_github_branch_path?(_), do: false

  defp valid_github_branch_segments?(value) do
    value
    |> String.split("/")
    |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp normalize_site_dir(value) do
    value = trim_string(value)

    cond do
      value == "" -> "auto"
      String.downcase(value) == "auto" -> "auto"
      String.starts_with?(value, ["/", "\\"]) -> "auto"
      String.contains?(value, ["..", "\0", "\\"]) -> "auto"
      true -> value
    end
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(_value), do: ""

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"

  defp mark_profile_saved(socket, updated_profile) do
    socket
    |> assign(:profile, updated_profile)
    |> assign(:profile_save_status, "Saved")
  end

  defp design_preset_attrs("minimal") do
    %{
      accent_color: "#2563eb",
      text_color: "#111827",
      background_color: "#f8fafc",
      icon_color: "#2563eb",
      container_background_color: "#ffffff",
      tick_color: "#2563eb",
      container_pattern: "none",
      background_type: "solid",
      text_background: false,
      profile_opacity: 1.0,
      profile_blur: 0,
      container_opacity: 0.92,
      font_family: nil,
      cursor_style: "default"
    }
  end

  defp design_preset_attrs("terminal") do
    %{
      accent_color: "#22c55e",
      text_color: "#d1fae5",
      background_color: "#020617",
      icon_color: "#22c55e",
      container_background_color: "#07130f",
      tick_color: "#22c55e",
      container_pattern: "grid",
      pattern_color: "#22c55e",
      pattern_opacity: 0.12,
      background_type: "solid",
      text_background: false,
      profile_opacity: 1.0,
      profile_blur: 0,
      container_opacity: 0.86,
      font_family: "Consolas",
      cursor_style: "text"
    }
  end

  defp design_preset_attrs("neon") do
    %{
      accent_color: "#ec4899",
      text_color: "#fdf2f8",
      background_color: "#09090b",
      icon_color: "#22d3ee",
      container_background_color: "#181024",
      tick_color: "#22d3ee",
      container_pattern: "diagonal_lines",
      pattern_color: "#ec4899",
      pattern_opacity: 0.18,
      background_type: "gradient",
      text_background: true,
      profile_opacity: 0.96,
      profile_blur: 8,
      container_opacity: 0.74,
      font_family: "Inter",
      cursor_style: "pointer"
    }
  end

  defp design_preset_attrs("soft") do
    %{
      accent_color: "#d97706",
      text_color: "#3f2a1d",
      background_color: "#fff7ed",
      icon_color: "#c2410c",
      container_background_color: "#fffbeb",
      tick_color: "#d97706",
      container_pattern: "waves",
      pattern_color: "#fed7aa",
      pattern_opacity: 0.35,
      background_type: "solid",
      text_background: false,
      profile_opacity: 1.0,
      profile_blur: 0,
      container_opacity: 0.9,
      font_family: "Georgia",
      cursor_style: "default"
    }
  end

  defp design_preset_attrs("high_contrast") do
    %{
      accent_color: "#facc15",
      text_color: "#ffffff",
      background_color: "#000000",
      icon_color: "#facc15",
      container_background_color: "#111111",
      tick_color: "#facc15",
      container_pattern: "none",
      background_type: "solid",
      text_background: true,
      profile_opacity: 1.0,
      profile_blur: 0,
      container_opacity: 0.95,
      font_family: "Arial",
      cursor_style: "default"
    }
  end

  defp design_preset_attrs("creator") do
    %{
      accent_color: "#7c3aed",
      text_color: "#f5f3ff",
      background_color: "#1e1b4b",
      icon_color: "#c4b5fd",
      container_background_color: "#312e81",
      tick_color: "#a78bfa",
      container_pattern: "dots",
      pattern_color: "#c4b5fd",
      pattern_opacity: 0.16,
      background_type: "gradient",
      text_background: true,
      profile_opacity: 0.98,
      profile_blur: 4,
      container_opacity: 0.82,
      font_family: "Inter",
      cursor_style: "pointer"
    }
  end

  defp design_preset_attrs(_), do: nil

  defp design_reset_attrs("colors") do
    reset_defaults(
      ~w(accent_color text_color background_color icon_color container_background_color tick_color pattern_color)a
    )
  end

  defp design_reset_attrs("background") do
    reset_defaults(~w(background_color background_type text_background)a)
    |> Map.merge(%{background_url: nil, background_size: nil})
  end

  defp design_reset_attrs("container") do
    reset_defaults(
      ~w(container_background_color container_pattern pattern_color pattern_animated pattern_animation_speed pattern_opacity container_opacity profile_blur)a
    )
  end

  defp design_reset_attrs("motion") do
    reset_defaults(
      ~w(profile_opacity profile_blur container_opacity pattern_opacity cursor_style)a
    )
  end

  defp design_reset_attrs("all") do
    reset_defaults(
      ~w(accent_color text_color background_color icon_color container_background_color tick_color container_pattern pattern_color pattern_animated pattern_animation_speed pattern_opacity background_type text_background profile_opacity profile_blur container_opacity cursor_style)a
    )
    |> Map.merge(%{background_url: nil, background_size: nil, font_family: nil})
  end

  defp design_reset_attrs(_), do: %{}

  defp reset_defaults(fields) do
    Map.new(fields, fn field -> {field, UserProfile.default(field)} end)
  end

  defp find_profile_link(profile, link_id) do
    case parse_positive_int(link_id) do
      {:ok, link_id} -> Enum.find(profile.links || [], &(&1.id == link_id))
      :error -> nil
    end
  end

  defp find_profile_widget(profile, widget_id) do
    case parse_positive_int(widget_id) do
      {:ok, widget_id} -> Enum.find(profile.widgets || [], &(&1.id == widget_id))
      :error -> nil
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_positive_int(_), do: :error

  defp humanize_error(:too_large), do: "File is too large for this upload"
  defp humanize_error(:not_accepted), do: "This file type is not supported for this upload"
  defp humanize_error(:too_many_files), do: "Only one file can be uploaded at a time"
  defp humanize_error(err), do: "Upload error: #{inspect(err)}"

  defp normalize_selected_tab(tab) when tab in @valid_tabs, do: tab

  defp normalize_selected_tab(tab) when is_map_key(@tab_aliases, tab), do: @tab_aliases[tab]

  defp normalize_selected_tab(_tab), do: @default_tab

  defp profile_tabs do
    @profile_tabs
  end
end
