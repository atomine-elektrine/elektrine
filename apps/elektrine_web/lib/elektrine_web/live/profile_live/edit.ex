defmodule ElektrineWeb.ProfileLive.Edit do
  use ElektrineWeb, :live_view
  alias Elektrine.Constants
  alias Elektrine.Profiles
  alias Elektrine.StaticSites

  @max_links Constants.max_profile_links()
  @max_widgets Constants.max_profile_widgets()

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    profile = Profiles.get_user_profile(user.id)

    # Create default profile if none exists
    profile =
      if profile do
        profile
      else
        case Profiles.create_user_profile(user.id, %{
               display_name: user.username
             }) do
          {:ok, _new_profile} -> Profiles.get_user_profile(user.id)
          _ -> nil
        end
      end

    user_badges = Profiles.list_user_badges(user.id)

    # Get static site info
    static_site_files = StaticSites.list_files(user.id)
    static_site_storage = StaticSites.total_storage_used(user.id)

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
     |> assign(:user_badges, user_badges)
     |> assign(:editing_link_id, nil)
     |> assign(:editing_link_data, %{})
     |> assign(:selected_platform, "custom")
     |> assign(:static_site_files, static_site_files)
     |> assign(:static_site_storage, static_site_storage)
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
         ~w(.html .htm .css .js .json .txt .png .jpg .jpeg .gif .webp .svg .ico .woff .woff2 .ttf .otf),
       max_entries: 20,
       max_file_size: 50 * 1024 * 1024,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _url, socket) do
    # Set tab from URL parameter
    {:noreply, assign(socket, :selected_tab, tab)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Default to basic tab if no tab specified
    {:noreply, assign(socket, :selected_tab, "basic")}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    # Update URL with tab parameter so it persists on refresh
    {:noreply, push_patch(socket, to: ~p"/account/profile/edit?tab=#{tab}")}
  end

  @impl true
  def handle_event("validate_profile", %{"profile" => _profile_params}, socket) do
    {:noreply, socket}
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

  def handle_event("update_color", %{"profile" => profile_params, "_target" => target}, socket) do
    if socket.assigns.profile do
      # Extract the field name from target (e.g., ["profile", "text_color"] -> "text_color")
      field_name = List.last(target)
      color = Map.get(profile_params, field_name)

      if color && field_name in Enum.map(@valid_color_fields, &Atom.to_string/1) do
        field_atom = String.to_existing_atom(field_name)
        attrs = %{field_atom => color}

        case Profiles.update_user_profile(socket.assigns.profile, attrs) do
          {:ok, updated_profile} ->
            {:noreply, assign(socket, :profile, updated_profile)}

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

      if value do
        # Convert field name to atom and parse value appropriately
        field_atom = String.to_existing_atom(field_name)

        parsed_value =
          case field_name do
            "profile_opacity" ->
              # Handle both integer and float strings
              if String.contains?(value, ".") do
                String.to_float(value)
              else
                String.to_integer(value) / 1.0
              end

            "container_opacity" ->
              # Handle both integer and float strings
              if String.contains?(value, ".") do
                String.to_float(value)
              else
                String.to_integer(value) / 1.0
              end

            "pattern_opacity" ->
              # Handle both integer and float strings
              if String.contains?(value, ".") do
                String.to_float(value)
              else
                String.to_integer(value) / 1.0
              end

            "profile_blur" ->
              String.to_integer(value)

            _ ->
              value
          end

        attrs = %{field_atom => parsed_value}

        case Profiles.update_user_profile(socket.assigns.profile, attrs) do
          {:ok, updated_profile} ->
            {:noreply, assign(socket, :profile, updated_profile)}

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
          {:noreply, assign(socket, :profile, updated_profile)}

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

      if color do
        # Convert field name to atom and create attrs map
        field_atom = String.to_existing_atom(field_name)
        attrs = %{field_atom => color}

        case Profiles.update_user_profile(socket.assigns.profile, attrs) do
          {:ok, updated_profile} ->
            {:noreply, assign(socket, :profile, updated_profile)}

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
      font_value = if font_family == "", do: nil, else: font_family

      case Profiles.update_user_profile(socket.assigns.profile, %{font_family: font_value}) do
        {:ok, updated_profile} ->
          {:noreply, assign(socket, :profile, updated_profile)}

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
          {:noreply, assign(socket, :profile, updated_profile)}

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
          {:noreply, assign(socket, :profile, updated_profile)}

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
          {:noreply, assign(socket, :profile, updated_profile)}

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
          {:noreply,
           socket
           |> assign(:profile, updated_profile)
           |> notify_info("Color palette generated!")}

        {:error, _changeset} ->
          {:noreply, notify_error(socket, "Failed to update colors")}
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

      if current_count >= @max_links do
        {:noreply, notify_error(socket, "Maximum #{@max_links} links allowed")}
      else
        # Ensure all keys are strings
        clean_params =
          for {key, value} <- link_params, into: %{} do
            {to_string(key), to_string(value)}
          end

        # Fetch thumbnail automatically if URL is provided and no thumbnail yet
        clean_params =
          if clean_params["url"] &&
               (!clean_params["thumbnail_url"] || clean_params["thumbnail_url"] == "") do
            # Fetch metadata in background and get image
            Task.start(fn ->
              case fetch_link_thumbnail(clean_params["url"]) do
                {:ok, thumbnail_url} ->
                  # Update the link after creation
                  # Brief delay to let creation complete
                  :timer.sleep(100)
                  profile = Profiles.get_user_profile(socket.assigns.profile.user_id)

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
            updated_profile = Profiles.get_user_profile(socket.assigns.user.id)

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
      link = Enum.find(socket.assigns.profile.links, &(&1.id == String.to_integer(link_id)))

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

        case Profiles.update_profile_link(link, clean_params) do
          {:ok, _updated_link} ->
            # Reload profile with updated links
            updated_profile = Profiles.get_user_profile(socket.assigns.user.id)

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

  @impl true
  def handle_event("delete_link", %{"id" => link_id}, socket) do
    # Find the link and delete it
    if socket.assigns.profile do
      link = Enum.find(socket.assigns.profile.links, &(&1.id == String.to_integer(link_id)))

      if link do
        case Profiles.delete_profile_link(link) do
          {:ok, _} ->
            # Reload profile with updated links
            updated_profile = Profiles.get_user_profile(socket.assigns.user.id)

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

      if current_count >= @max_widgets do
        {:noreply, notify_error(socket, "Maximum #{@max_widgets} widgets allowed")}
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
            updated_profile = Profiles.get_user_profile(socket.assigns.user.id)

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
      widget = Enum.find(socket.assigns.profile.widgets, &(&1.id == String.to_integer(widget_id)))

      if widget do
        case Profiles.delete_widget(widget.id) do
          {:ok, _} ->
            # Reload profile with updated widgets
            updated_profile = Profiles.get_user_profile(socket.assigns.user.id)

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
    badge_id = String.to_integer(badge_id)
    badge = Enum.find(socket.assigns.user_badges, &(&1.id == badge_id))

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
    link_id = String.to_integer(link_id)
    links = socket.assigns.profile.links
    link_index = Enum.find_index(links, &(&1.id == link_id))

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
        updated_profile = Profiles.get_user_profile(socket.assigns.user.id)
        {:noreply, assign(socket, :profile, updated_profile)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_widget", %{"id" => widget_id, "direction" => direction}, socket) do
    widget_id = String.to_integer(widget_id)
    widgets = socket.assigns.profile.widgets
    widget_index = Enum.find_index(widgets, &(&1.id == widget_id))

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
        updated_profile = Profiles.get_user_profile(socket.assigns.user.id)
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
      |> convert_checkbox_to_boolean_if_present("show_discord_presence")
      |> convert_checkbox_to_boolean_if_present("use_discord_avatar")
      |> convert_checkbox_to_boolean_if_present("hide_view_counter")
      |> convert_checkbox_to_boolean_if_present("hide_uid")
      |> convert_checkbox_to_boolean_if_present("hide_followers")
      |> convert_checkbox_to_boolean_if_present("hide_avatar")
      |> convert_checkbox_to_boolean_if_present("hide_timeline")
      |> convert_checkbox_to_boolean_if_present("hide_community_posts")
      |> convert_checkbox_to_boolean_if_present("hide_share_button")
      |> convert_checkbox_to_boolean_if_present("extend_layout")
      |> convert_checkbox_to_boolean_if_present("text_background")
      |> convert_checkbox_to_boolean_if_present("typewriter_effect")
      |> convert_checkbox_to_boolean_if_present("typewriter_title")
      |> convert_checkbox_to_boolean_if_present("pattern_animated")

    # Convert empty string font_family to nil for "System Default"
    profile_params =
      if Map.has_key?(profile_params, "font_family") && profile_params["font_family"] == "" do
        Map.put(profile_params, "font_family", nil)
      else
        profile_params
      end

    result = Profiles.upsert_user_profile(socket.assigns.user.id, profile_params)

    case result do
      {:ok, _updated_profile} ->
        # Force reload profile with links
        refreshed_profile = Profiles.get_user_profile(socket.assigns.user.id)

        {:noreply,
         socket
         |> assign(:profile, refreshed_profile)
         |> notify_info("Profile updated successfully!")
         |> push_event("profile_updated", %{})}

      {:error, changeset} ->
        error_msg = "Failed to update profile: #{inspect(changeset.errors)}"

        {:noreply,
         socket
         |> notify_error(error_msg)}
    end
  end

  # Static Site Handlers

  def handle_event("set_profile_mode", %{"mode" => mode}, socket) do
    case mode do
      "static" ->
        case StaticSites.enable_static_mode(socket.assigns.user.id) do
          {:ok, _} ->
            profile = Profiles.get_user_profile(socket.assigns.user.id)

            {:noreply,
             socket |> assign(:profile, profile) |> notify_info("Static site mode enabled")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to enable static mode")}
        end

      "builder" ->
        case StaticSites.enable_builder_mode(socket.assigns.user.id) do
          {:ok, _} ->
            profile = Profiles.get_user_profile(socket.assigns.user.id)

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

              {:error, reason} ->
                Logger.error("Upload failed: #{inspect(reason)}")
                {:ok, {:error, reason}}

              {:error, :partial_upload, errors} ->
                Logger.error("Partial upload, errors: #{inspect(errors)}")
                {:ok, {:error, :partial_upload}}
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

        {:noreply,
         socket
         |> assign(:static_site_files, static_site_files)
         |> assign(:static_site_storage, static_site_storage)
         |> notify_info("Uploaded #{count} files successfully")}

      [{:error, :storage_limit_exceeded}] ->
        {:noreply, notify_error(socket, "Storage limit exceeded (50MB max)")}

      [{:error, :file_limit_exceeded}] ->
        {:noreply, notify_error(socket, "File limit exceeded (100 files max)")}

      [{:error, _reason}] ->
        {:noreply, notify_error(socket, "Failed to upload static site")}

      [] ->
        {:noreply, socket}
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
    user = socket.assigns.user

    uploaded_files =
      consume_uploaded_entries(socket, :static_files, fn %{path: path}, entry ->
        # Read the file content
        case File.read(path) do
          {:ok, binary} ->
            # Use the client filename as the path
            file_path = entry.client_name
            content_type = entry.client_type || MIME.from_path(file_path)

            case StaticSites.upload_file(user, file_path, binary, content_type) do
              {:ok, _file} -> {:ok, :success}
              {:error, reason} -> {:ok, {:error, reason}}
            end

          {:error, reason} ->
            {:ok, {:error, reason}}
        end
      end)

    success_count = Enum.count(uploaded_files, &(&1 == :success))
    error_count = Enum.count(uploaded_files, &match?({:error, _}, &1))

    static_site_files = StaticSites.list_files(user.id)
    static_site_storage = StaticSites.total_storage_used(user.id)

    socket =
      socket
      |> assign(:static_site_files, static_site_files)
      |> assign(:static_site_storage, static_site_storage)

    cond do
      success_count > 0 and error_count == 0 ->
        {:noreply, notify_info(socket, "Uploaded #{success_count} file(s)")}

      success_count > 0 and error_count > 0 ->
        {:noreply,
         notify_info(socket, "Uploaded #{success_count} file(s), #{error_count} failed")}

      true ->
        {:noreply, notify_error(socket, "Failed to upload files")}
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

  # Helper functions for username intensity parsing
  defp parse_username_intensity(nil), do: nil
  defp parse_username_intensity(value) when is_binary(value), do: String.to_integer(value)
  defp parse_username_intensity(value), do: value

  # Helper function to fetch link thumbnail
  defp fetch_link_thumbnail(url) do
    # Reuse link preview fetcher to get og:image or favicon
    case Elektrine.Social.LinkPreviewFetcher.fetch_preview_metadata(url) do
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
      # Always white for readability
      text_color: "#ffffff",
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

  defp hex_to_rgb("#" <> hex) do
    {r, _} = Integer.parse(String.slice(hex, 0, 2), 16)
    {g, _} = Integer.parse(String.slice(hex, 2, 2), 16)
    {b, _} = Integer.parse(String.slice(hex, 4, 2), 16)
    {r, g, b}
  end

  # Default purple
  defp hex_to_rgb(_hex), do: {139, 92, 246}

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
    {r, g, b} = hex_to_rgb(hex)
    rgb_to_hex(r * (1 - factor), g * (1 - factor), b * (1 - factor))
  end

  defp lighten_color(hex, factor) do
    {r, g, b} = hex_to_rgb(hex)
    rgb_to_hex(r + (255 - r) * factor, g + (255 - g) * factor, b + (255 - b) * factor)
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

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"

  defp humanize_error(:too_large), do: "File is too large (max 50MB)"
  defp humanize_error(:not_accepted), do: "File type not accepted. Only ZIP files are allowed."
  defp humanize_error(:too_many_files), do: "Only one file can be uploaded at a time"
  defp humanize_error(err), do: "Upload error: #{inspect(err)}"
end
