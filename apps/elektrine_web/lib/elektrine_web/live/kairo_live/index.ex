defmodule ElektrineWeb.KairoLive.Index do
  use ElektrineWeb, :live_view

  @source_page 200
  @max_sources 1000
  @kairo_upload_extensions ~w(.jpg .jpeg .png .gif .webp .heic .heif .avif .pdf .doc .docx .xls .xlsx .txt .md .markdown .json)

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

      user ->
        {:ok,
         socket
         |> assign(:query, "")
         |> assign(:active_tag, nil)
         |> assign(:active_project, nil)
         |> assign(:selected_id, nil)
         |> assign(:view_mode, "reader")
         |> assign(:composing, false)
         |> assign(:adding_link, false)
         |> assign(:editing_source_id, nil)
         |> assign(:compose, empty_compose())
         |> assign(:compose_tab, "write")
         |> assign(:source_limit, @source_page)
         |> allow_upload(:kairo_files,
           accept: @kairo_upload_extensions,
           max_entries: 5,
           max_file_size: Elektrine.Constants.max_chat_attachment_size()
         )
         |> load_kairo(user)}
    end
  end

  @impl true
  def handle_event("create_project", %{"project" => params}, socket) do
    user = socket.assigns.current_user

    case Kairo.create_project(user, params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> load_kairo(user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Project could not be created")}
    end
  end

  def handle_event("rename_project", %{"project" => %{"id" => id, "name" => name}}, socket) do
    user = socket.assigns.current_user

    case Kairo.update_project(user, id, %{"name" => name}) do
      {:ok, _project} ->
        {:noreply, socket |> put_flash(:info, "Project renamed") |> load_kairo(user)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Project could not be renamed")}
    end
  end

  def handle_event("toggle_archive_project", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %Kairo.Project{} = project <- Kairo.get_project(user, id),
         next_status = if(project.status == "archived", do: "active", else: "archived"),
         {:ok, updated} <- Kairo.update_project(user, id, %{"status" => next_status}) do
      verb = if updated.status == "archived", do: "archived", else: "restored"
      {:noreply, socket |> put_flash(:info, "Project #{verb}") |> load_kairo(user)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Project could not be updated")}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Kairo.delete_project(user, id) do
      {:ok, project} ->
        active =
          if socket.assigns.active_project == project.id,
            do: nil,
            else: socket.assigns.active_project

        {:noreply,
         socket
         |> assign(:active_project, active)
         |> put_flash(:info, "Project deleted - its sources moved to the inbox")
         |> load_kairo(user)}

      _error ->
        {:noreply, put_flash(socket, :error, "Project could not be deleted")}
    end
  end

  def handle_event("load_more", _params, socket) do
    limit = min(socket.assigns.source_limit + @source_page, @max_sources)

    {:noreply,
     socket
     |> assign(:source_limit, limit)
     |> load_kairo(socket.assigns.current_user)}
  end

  def handle_event("toggle_add_link", _params, socket) do
    {:noreply, assign(socket, :adding_link, not socket.assigns.adding_link)}
  end

  def handle_event("save_link", %{"link" => link}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "source_type" => "url",
      "url" => link["url"],
      "title" => link["title"],
      "tags" => link["tags"],
      "project_id" => blank_to_nil(link["project_id"])
    }

    case Kairo.create_source(user, attrs) do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(:adding_link, false)
         |> assign(:selected_id, source.id)
         |> put_flash(:info, "Link saved - fetching its content in the background")
         |> load_kairo(user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Enter a valid URL first.")}
    end
  end

  def handle_event("validate_kairo_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_kairo_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :kairo_files, ref)}
  end

  def handle_event("upload_kairo_files", %{"upload" => upload_params}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "project_id" => blank_to_nil(upload_params["project_id"]),
      "tags" => upload_params["tags"]
    }

    results =
      consume_uploaded_entries(socket, :kairo_files, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        {:ok, Kairo.create_upload_source(user, upload, attrs)}
      end)

    successes = for {:ok, source} <- results, do: source
    failures = for {:error, reason} <- results, do: reason

    cond do
      successes != [] and failures == [] ->
        {:noreply,
         socket
         |> assign(:selected_id, List.last(successes).id)
         |> put_flash(:info, upload_success_message(successes))
         |> load_kairo(user)}

      successes != [] ->
        {:noreply,
         socket
         |> assign(:selected_id, List.last(successes).id)
         |> put_flash(:error, "Some files could not be saved.")
         |> load_kairo(user)}

      true ->
        {:noreply, put_flash(socket, :error, "Choose a supported file first.")}
    end
  end

  def handle_event("upload_kairo_files", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose a supported file first.")}
  end

  # Zero-knowledge save: the KairoVault hook encrypts the body client-side and
  # pushes the ciphertext envelope; plaintext content is never persisted.
  def handle_event("save_encrypted_note", %{"note" => note, "payload" => payload}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "source_type" => "markdown",
      "content_format" => "markdown",
      "title" => note["title"],
      "tags" => note["tags"],
      "project_id" => blank_to_nil(note["project_id"]),
      "encrypted" => true,
      "encrypted_content" => payload
    }

    case Kairo.create_source(user, attrs) do
      {:ok, source} ->
        {:reply, %{ok: true},
         socket
         |> assign(:composing, false)
         |> assign(:selected_id, source.id)
         |> put_flash(:info, "Encrypted note saved")
         |> load_kairo(user)}

      {:error, _changeset} ->
        {:reply, %{ok: false, error: "Could not save the encrypted note."}, socket}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign_view()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:query, "") |> assign_view()}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    active = if socket.assigns.active_tag == tag, do: nil, else: tag
    {:noreply, socket |> assign(:active_tag, active) |> assign_view()}
  end

  def handle_event("filter_project", %{"project" => project}, socket) do
    value = parse_project_filter(project)
    active = if socket.assigns.active_project == value, do: nil, else: value
    {:noreply, socket |> assign(:active_project, active) |> assign_view()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:active_tag, nil)
     |> assign(:active_project, nil)
     |> assign_view()}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) when mode in ~w(reader graph) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("select_source", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:composing, false)
     |> assign(:view_mode, "reader")
     |> assign(:selected_id, parse_id(id))
     |> assign_view()}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, "reader")
     |> assign(:composing, true)
     |> assign(:editing_source_id, nil)
     |> assign(:selected, nil)
     |> assign(:selected_id, nil)
     |> assign(:compose, empty_compose())
     |> assign(:compose_tab, "write")}
  end

  def handle_event("cancel_note", _params, socket) do
    {:noreply, socket |> assign(:composing, false) |> assign(:editing_source_id, nil)}
  end

  def handle_event("set_compose_tab", %{"tab" => tab}, socket) when tab in ~w(write preview) do
    {:noreply, assign(socket, :compose_tab, tab)}
  end

  def handle_event("compose_change", %{"note" => note}, socket) do
    {:noreply, assign(socket, :compose, Map.merge(empty_compose(), note))}
  end

  def handle_event("save_note", %{"note" => %{"encrypt" => "true"}}, socket) do
    # Backstop: encrypted notes are saved by the KairoVault hook via
    # save_encrypted_note. If the plain submit fires anyway (vault locked, JS
    # unavailable), refuse rather than store the plaintext.
    {:noreply,
     put_flash(socket, :error, "Enter your account password to save an encrypted note.")}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    user = socket.assigns.current_user

    case socket.assigns.editing_source do
      nil ->
        attrs = %{
          "source_type" => "markdown",
          "content_format" => "markdown",
          "title" => note["title"],
          "content" => note["content"],
          "tags" => note["tags"],
          "project_id" => blank_to_nil(note["project_id"])
        }

        case Kairo.create_source(user, attrs) do
          {:ok, source} ->
            {:noreply,
             socket
             |> assign(:composing, false)
             |> assign(:selected_id, source.id)
             |> put_flash(:info, "Note saved")
             |> load_kairo(user)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Add a title or some content first.")}
        end

      source ->
        attrs = source_update_attrs(source, note)

        case Kairo.update_source(user, source.id, attrs) do
          {:ok, updated_source} ->
            {:noreply,
             socket
             |> assign(:composing, false)
             |> assign(:editing_source_id, nil)
             |> assign(:selected_id, updated_source.id)
             |> put_flash(:info, "Source updated")
             |> load_kairo(user)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> assign(:composing, false)
             |> assign(:editing_source_id, nil)
             |> put_flash(:error, "Source not found")
             |> load_kairo(user)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Source could not be updated")}
        end
    end
  end

  def handle_event("edit_source", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Kairo.get_source(user, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      source ->
        {:noreply,
         socket
         |> assign(:view_mode, "reader")
         |> assign(:composing, true)
         |> assign(:editing_source_id, source.id)
         |> assign(:selected_id, source.id)
         |> assign(:compose, compose_from_source(source))
         |> assign(:compose_tab, "write")
         |> assign_view()}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    source_id = parse_id(id)

    case Kairo.delete_source(user, source_id) do
      {:ok, _source} ->
        socket =
          socket
          |> assign(:composing, false)
          |> assign(:editing_source_id, nil)
          |> maybe_clear_selected(source_id)
          |> put_flash(:info, "Source deleted")
          |> load_kairo(user)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Source could not be deleted")}
    end
  end

  defp empty_compose,
    do: %{"title" => "", "content" => "", "project_id" => "", "tags" => "", "encrypt" => ""}

  defp compose_from_source(source) do
    %{
      "title" => source.title || "",
      "content" => source.content || "",
      "project_id" => source.project_id || "",
      "tags" => Enum.join(source.tags || [], ", ")
    }
  end

  defp source_update_attrs(source, note) do
    attrs = %{
      "source_type" => source.source_type || "markdown",
      "content_format" => source.content_format || "markdown",
      "title" => note["title"],
      "tags" => note["tags"],
      "project_id" => blank_to_nil(note["project_id"])
    }

    if source.encrypted do
      attrs
    else
      Map.put(attrs, "content", note["content"])
    end
  end

  defp maybe_clear_selected(socket, source_id) do
    if socket.assigns.selected_id == source_id do
      assign(socket, :selected_id, nil)
    else
      socket
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_project_filter("inbox"), do: :inbox
  defp parse_project_filter(id), do: parse_id(id)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp load_kairo(socket, user) do
    socket
    |> assign(:page_title, "Kairo")
    |> assign(:projects, Kairo.list_projects(user))
    |> assign(:sources, Kairo.list_sources(user, limit: socket.assigns.source_limit))
    |> assign(:sources_total, Kairo.count_sources(user))
    |> assign(:master_vault, Elektrine.Vault.get(user.id))
    |> assign(:project_form, to_form(%{"name" => "", "description" => ""}, as: :project))
    |> assign_view()
  end

  # Derives the filtered explorer view from the current sources/query/tag/selection.
  defp assign_view(socket) do
    %{
      sources: sources,
      query: query,
      active_tag: active_tag,
      active_project: active_project,
      selected_id: selected_id
    } = socket.assigns

    visible = visible_sources(sources, query, active_tag, active_project)
    selected = Enum.find(sources, &(&1.id == selected_id))
    editing_source = Enum.find(sources, &(&1.id == socket.assigns.editing_source_id))

    socket
    |> assign(:all_tags, all_tags(sources))
    |> assign(
      :active_project_record,
      Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.active_project))
    )
    |> assign(:folders, folders(visible, socket.assigns.projects))
    |> assign(:visible_count, length(visible))
    |> assign(:selected, selected)
    |> assign(:editing_source, editing_source)
    |> assign(:related, related_sources(sources, selected))
    |> assign(:has_encrypted_sources, Enum.any?(sources, & &1.encrypted))
    |> assign(:graph, build_graph(visible, socket.assigns.projects))
  end

  # Palette for project-colored source nodes. Inbox (no project) falls back to a
  # neutral gray. Mid-tone hues so they read on both light and dark themes.
  @project_palette ~w(#6366f1 #ec4899 #14b8a6 #f59e0b #8b5cf6 #ef4444 #10b981 #3b82f6)
  @inbox_color "#9ca3af"

  # Cap on how many of its strongest neighbors each source links to. Keeps the
  # graph sparse and readable (and cheap to animate) even when many sources share
  # a common tag, which would otherwise produce a near-complete graph.
  @max_edges_per_source 5

  # Graph: one node per source (file), with an edge between two
  # sources that share tags. Edge weight is the number of shared tags. To avoid a
  # hairball, each source only links to its strongest few neighbors. Sources are
  # colored by project; untagged or unconnected sources appear as lone nodes.
  defp build_graph(sources, projects) do
    colors = project_colors(projects)

    nodes =
      Enum.map(sources, fn source ->
        %{
          id: "s-#{source.id}",
          ref: source.id,
          label: source_label(source),
          color: Map.get(colors, source.project_id, @inbox_color)
        }
      end)

    tagged =
      sources
      |> Enum.map(fn source -> {source.id, MapSet.new(source.tags || [])} end)
      |> Enum.reject(fn {_id, tags} -> MapSet.size(tags) == 0 end)

    pairs =
      for {id_a, tags_a} <- tagged,
          {id_b, tags_b} <- tagged,
          id_a < id_b,
          shared = MapSet.size(MapSet.intersection(tags_a, tags_b)),
          shared > 0 do
        {id_a, id_b, shared}
      end

    edges =
      pairs
      |> strongest_edges(@max_edges_per_source)
      |> Enum.map(fn {id_a, id_b, weight} ->
        %{source: "s-#{id_a}", target: "s-#{id_b}", weight: weight}
      end)

    %{nodes: nodes, edges: edges}
  end

  # Keeps, for each source, only its `max` highest-weight pairs, then unions
  # those choices so an edge survives if either endpoint ranks it.
  defp strongest_edges(pairs, max) do
    pairs
    |> Enum.reduce(%{}, fn {a, b, _w} = pair, acc ->
      acc
      |> Map.update(a, [pair], &[pair | &1])
      |> Map.update(b, [pair], &[pair | &1])
    end)
    |> Enum.flat_map(fn {_id, node_pairs} ->
      node_pairs
      |> Enum.sort_by(fn {_a, _b, w} -> -w end)
      |> Enum.take(max)
    end)
    |> Enum.uniq()
  end

  defp project_colors(projects) do
    projects
    |> Enum.with_index()
    |> Map.new(fn {project, index} ->
      {project.id, Enum.at(@project_palette, rem(index, length(@project_palette)))}
    end)
  end

  defp visible_sources(sources, query, active_tag, active_project) do
    Enum.filter(
      sources,
      &(project_match?(&1, active_project) and tag_match?(&1, active_tag) and
          query_match?(&1, query))
    )
  end

  defp project_match?(_source, nil), do: true
  defp project_match?(source, :inbox), do: is_nil(source.project_id)
  defp project_match?(source, project_id), do: source.project_id == project_id

  defp tag_match?(_source, nil), do: true
  defp tag_match?(source, tag), do: tag in (source.tags || [])

  defp query_match?(_source, ""), do: true
  defp query_match?(_source, nil), do: true

  defp query_match?(source, query) do
    needle = String.downcase(String.trim(query))

    [source.title, source.url, source.source_type, source.content | source.tags || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  defp folders(visible, projects) do
    by_project = Enum.group_by(visible, & &1.project_id)

    project_folders =
      projects
      |> Enum.map(fn project ->
        %{id: project.id, name: project.name, sources: Map.get(by_project, project.id, [])}
      end)
      |> Enum.reject(&(&1.sources == []))

    inbox = Map.get(by_project, nil, [])

    if inbox == [],
      do: project_folders,
      else: [%{id: nil, name: "Inbox", sources: inbox} | project_folders]
  end

  defp all_tags(sources) do
    sources
    |> Enum.flat_map(&(&1.tags || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp related_sources(_sources, nil), do: []

  defp related_sources(sources, %{tags: tags} = selected) when is_list(tags) and tags != [] do
    tag_set = MapSet.new(tags)

    sources
    |> Enum.reject(&(&1.id == selected.id))
    |> Enum.filter(fn source ->
      Enum.any?(source.tags || [], &MapSet.member?(tag_set, &1))
    end)
    |> Enum.take(8)
  end

  defp related_sources(_sources, _selected), do: []

  defp source_label(source) do
    cond do
      present?(source.title) -> source.title
      present?(source.url) -> source.url
      true -> "Untitled #{String.replace(source.source_type || "source", "_", " ")}"
    end
  end

  defp source_icon(%{encrypted: true}), do: "hero-lock-closed"
  defp source_icon(%{source_type: "image"}), do: "hero-photo"
  defp source_icon(%{source_type: "pdf"}), do: "hero-document"
  defp source_icon(%{source_type: "file"}), do: "hero-paper-clip"
  defp source_icon(_source), do: "hero-document-text"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp preformatted_content?(%{content_format: format}) when format in ["text", "json"], do: true
  defp preformatted_content?(_source), do: false

  defp upload_success_message([_one]), do: "File saved"
  defp upload_success_message(sources), do: "#{length(sources)} files saved"

  defp upload_error_text(:too_large), do: "File is too large"
  defp upload_error_text(:too_many_files), do: "Too many files"
  defp upload_error_text(:not_accepted), do: "Unsupported file type"
  defp upload_error_text(error), do: Phoenix.Naming.humanize(to_string(error))

  defp source_file_url(source) do
    with key when is_binary(key) <- source_file_key(source),
         url when is_binary(url) <-
           Elektrine.Uploads.attachment_url(key, %{visibility: "private"}) do
      url
    else
      _ -> nil
    end
  end

  defp source_file_key(%{metadata: metadata}) when is_map(metadata) do
    metadata["storage_key"] || metadata[:storage_key] || metadata["key"] || metadata[:key]
  end

  defp source_file_key(_source), do: nil

  defp source_file_content_type(%{metadata: metadata}) when is_map(metadata) do
    metadata["content_type"] || metadata[:content_type]
  end

  defp source_file_content_type(_source), do: nil

  defp source_file_name(%{metadata: metadata} = source) when is_map(metadata) do
    metadata["original_filename"] || metadata[:original_filename] || metadata["filename"] ||
      metadata[:filename] || source_label(source)
  end

  defp source_file_name(source), do: source_label(source)

  defp source_file_size(%{metadata: metadata}) when is_map(metadata) do
    metadata["size"] || metadata[:size]
  end

  defp source_file_size(_source), do: nil

  defp source_image?(source) do
    source.source_type == "image" or
      (source_file_content_type(source) || "") |> String.starts_with?("image/")
  end

  defp source_pdf?(source) do
    source.source_type == "pdf" or source_file_content_type(source) == "application/pdf"
  end

  defp format_file_size(size) when is_integer(size) and size >= 1_048_576 do
    "#{Float.round(size / 1_048_576, 1)} MB"
  end

  defp format_file_size(size) when is_integer(size) and size >= 1024 do
    "#{Float.round(size / 1024, 1)} KB"
  end

  defp format_file_size(size) when is_integer(size), do: "#{size} B"
  defp format_file_size(_size), do: nil

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl px-4 pb-2 sm:px-6 lg:px-8">
      <section>
        <.e_nav active_tab="kairo" current_user={@current_user} class="mb-6" />

        <div
          id="kairo-vault"
          phx-hook="KairoVault"
          data-kairo-master-configured={to_string(not is_nil(@master_vault))}
          data-kairo-master-wrapped-dek={@master_vault && Jason.encode!(@master_vault.wrapped_dek)}
        >
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-[18rem_minmax(0,1fr)] lg:gap-6">
            <%!-- Explorer --%>
            <aside class="card panel-card flex flex-col overflow-hidden border border-base-300 lg:max-h-[calc(100vh-8rem)]">
              <div class="space-y-2 border-b border-base-300 p-3">
                <div class="flex gap-2">
                  <button type="button" phx-click="new_note" class="btn btn-primary btn-sm flex-1">
                    <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_add_link"
                    class={["btn btn-sm", if(@adding_link, do: "btn-active", else: "btn-outline")]}
                    title="Save a link"
                  >
                    <.icon name="hero-link" class="h-4 w-4" />
                  </button>
                </div>

                <form
                  :if={@adding_link}
                  phx-submit="save_link"
                  class="space-y-2 rounded-lg border border-base-300 bg-base-200/40 p-2"
                >
                  <input
                    type="url"
                    name="link[url]"
                    required
                    placeholder="https://…"
                    autocomplete="off"
                    class="input input-bordered input-sm w-full"
                  />
                  <input
                    type="text"
                    name="link[title]"
                    placeholder="Title (optional, fetched if empty)"
                    autocomplete="off"
                    class="input input-bordered input-sm w-full"
                  />
                  <div class="grid grid-cols-2 gap-2">
                    <select name="link[project_id]" class="select select-bordered select-sm">
                      <option value="">Inbox</option>
                      <option :for={project <- @projects} value={project.id}>{project.name}</option>
                    </select>
                    <input
                      type="text"
                      name="link[tags]"
                      placeholder="tags, comma"
                      autocomplete="off"
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <button type="submit" class="btn btn-secondary btn-sm w-full">Save link</button>
                </form>

                <form
                  id="kairo-upload-form"
                  phx-change="validate_kairo_upload"
                  phx-submit="upload_kairo_files"
                  class="space-y-2 rounded-lg border border-base-300 bg-base-200/40 p-2"
                >
                  <div class="flex items-center gap-2">
                    <label for={@uploads.kairo_files.ref} class="btn btn-outline btn-sm flex-1">
                      <.icon name="hero-arrow-up-tray" class="h-4 w-4" /> Add files
                    </label>
                    <button type="submit" class="btn btn-secondary btn-sm">
                      Save
                    </button>
                  </div>
                  <div class="sr-only">
                    <.live_file_input upload={@uploads.kairo_files} />
                  </div>
                  <div class="grid grid-cols-2 gap-2">
                    <select name="upload[project_id]" class="select select-bordered select-sm">
                      <option value="">Inbox</option>
                      <option :for={project <- @projects} value={project.id}>{project.name}</option>
                    </select>
                    <input
                      type="text"
                      name="upload[tags]"
                      placeholder="tags, comma"
                      autocomplete="off"
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div :if={@uploads.kairo_files.entries != []} class="space-y-1">
                    <div
                      :for={entry <- @uploads.kairo_files.entries}
                      class="flex items-center gap-2 rounded bg-base-100 px-2 py-1 text-xs"
                    >
                      <.icon name="hero-paper-clip" class="h-3.5 w-3.5 shrink-0" />
                      <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
                      <span class="text-base-content/50">{entry.progress}%</span>
                      <button
                        type="button"
                        phx-click="cancel_kairo_upload"
                        phx-value-ref={entry.ref}
                        class="btn btn-ghost btn-xs h-6 min-h-0 w-6 p-0"
                        aria-label="Remove file"
                      >
                        <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>
                  <p
                    :for={error <- upload_errors(@uploads.kairo_files)}
                    class="text-xs text-error"
                  >
                    {upload_error_text(error)}
                  </p>
                </form>

                <form id="kairo-search-form" phx-change="search" phx-submit="search" class="relative">
                  <input
                    id="kairo-search"
                    type="text"
                    name="query"
                    value={@query}
                    placeholder="Search sources…"
                    autocomplete="off"
                    phx-debounce="150"
                    class="input input-bordered input-sm w-full pr-8"
                  />
                  <button
                    :if={@query != ""}
                    type="button"
                    phx-click="clear_search"
                    aria-label="Clear search"
                    class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/50 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </form>

                <div
                  :if={@has_encrypted_sources || @composing}
                  class="!mt-3 hidden flex-col gap-2 rounded-lg border border-warning/30 bg-warning/5 p-2"
                  data-kairo-locked-hint
                >
                  <%= if @master_vault do %>
                    <input
                      type="password"
                      class="input input-bordered input-xs w-full"
                      placeholder="Account password"
                      autocomplete="current-password"
                      data-kairo-master-unlock-input
                    />
                    <button
                      type="button"
                      class="btn btn-outline btn-xs w-full"
                      data-kairo-master-unlock
                    >
                      Unlock with account password
                    </button>
                  <% else %>
                    <span class="text-xs text-warning">
                      <.link navigate={~p"/account/encrypted-data"} class="link">
                        Set up account-password encryption
                      </.link>
                      to decrypt
                    </span>
                  <% end %>
                </div>
                <p class="hidden text-xs text-error" data-kairo-master-error></p>

                <div :if={@projects != []} class="space-y-1">
                  <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/50">
                    Projects
                  </p>
                  <div class="flex flex-wrap gap-1">
                    <button
                      :for={project <- @projects}
                      type="button"
                      phx-click="filter_project"
                      phx-value-project={project.id}
                      title={if(project.status == "archived", do: "Archived", else: nil)}
                      class={[
                        "badge badge-sm cursor-pointer gap-1",
                        if(@active_project == project.id, do: "badge-primary", else: "badge-outline"),
                        project.status == "archived" && "opacity-50"
                      ]}
                    >
                      <.icon
                        name={
                          if(project.status == "archived",
                            do: "hero-archive-box",
                            else: "hero-folder"
                          )
                        }
                        class="h-3 w-3"
                      /> {project.name}
                    </button>
                    <button
                      :if={Enum.any?(@sources, &is_nil(&1.project_id))}
                      type="button"
                      phx-click="filter_project"
                      phx-value-project="inbox"
                      class={[
                        "badge badge-sm cursor-pointer gap-1",
                        if(@active_project == :inbox, do: "badge-primary", else: "badge-outline")
                      ]}
                    >
                      <.icon name="hero-inbox" class="h-3 w-3" /> Inbox
                    </button>
                  </div>

                  <div :if={@active_project_record} class="!mt-3">
                    <div class="space-y-2 rounded-lg border border-base-300 bg-base-200/40 p-2">
                      <form phx-submit="rename_project" class="flex gap-1">
                        <input type="hidden" name="project[id]" value={@active_project_record.id} />
                        <input
                          type="text"
                          name="project[name]"
                          value={@active_project_record.name}
                          required
                          class="input input-bordered input-xs min-w-0 flex-1"
                        />
                        <button type="submit" class="btn btn-outline btn-xs" title="Rename">
                          <.icon name="hero-check" class="h-3 w-3" />
                        </button>
                      </form>
                      <div class="flex gap-1">
                        <button
                          type="button"
                          phx-click="toggle_archive_project"
                          phx-value-id={@active_project_record.id}
                          class="btn btn-outline btn-xs flex-1"
                        >
                          {if @active_project_record.status == "archived",
                            do: "Unarchive",
                            else: "Archive"}
                        </button>
                        <button
                          type="button"
                          phx-click="delete_project"
                          phx-value-id={@active_project_record.id}
                          data-confirm="Delete this project? Its sources will move to the inbox."
                          class="btn btn-error btn-outline btn-xs flex-1"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                  </div>
                </div>

                <div :if={@all_tags != []} class="space-y-1">
                  <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/50">
                    Tags
                  </p>
                  <div class="flex flex-wrap gap-1">
                    <button
                      :for={tag <- @all_tags}
                      type="button"
                      phx-click="filter_tag"
                      phx-value-tag={tag}
                      class={[
                        "badge badge-sm cursor-pointer",
                        if(@active_tag == tag, do: "badge-primary", else: "badge-ghost")
                      ]}
                    >
                      #{tag}
                    </button>
                  </div>
                </div>
              </div>

              <nav class="flex-1 space-y-1 overflow-y-auto p-2">
                <p :if={@visible_count == 0} class="px-2 py-4 text-sm text-base-content/60">
                  <%= if @sources == [] do %>
                    No sources yet. Start a new note or ingest via the API.
                  <% else %>
                    No matching sources.
                  <% end %>
                </p>

                <details :for={folder <- @folders} open class="group">
                  <summary class="flex cursor-pointer items-center justify-between rounded px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/60 hover:bg-base-300/40">
                    <span class="flex items-center gap-1">
                      <.icon
                        name="hero-chevron-right"
                        class="h-3 w-3 transition-transform group-open:rotate-90"
                      /> {folder.name}
                    </span>
                    <span class="opacity-60">{length(folder.sources)}</span>
                  </summary>
                  <ul class="mt-1 space-y-0.5">
                    <li :for={source <- folder.sources}>
                      <button
                        type="button"
                        phx-click="select_source"
                        phx-value-id={source.id}
                        class={[
                          "flex w-full items-center gap-1.5 truncate rounded px-2 py-1.5 text-left text-sm",
                          if(@selected && @selected.id == source.id,
                            do: "bg-primary/15 text-primary",
                            else: "hover:bg-base-300/40"
                          )
                        ]}
                      >
                        <.icon
                          name={source_icon(source)}
                          class="h-4 w-4 shrink-0"
                        />
                        <span class="truncate">{source_label(source)}</span>
                      </button>
                    </li>
                  </ul>
                </details>

                <button
                  :if={length(@sources) < @sources_total}
                  type="button"
                  phx-click="load_more"
                  class="btn btn-xs w-full load-more-button"
                >
                  Load more ({length(@sources)} of {@sources_total} loaded)
                </button>
              </nav>

              <div class="border-t border-base-300 p-2">
                <details class="group">
                  <summary class="flex cursor-pointer items-center gap-1 rounded px-2 py-1 text-xs text-base-content/70 hover:bg-base-300/40">
                    <.icon name="hero-plus" class="h-3.5 w-3.5" /> New project
                  </summary>
                  <.form for={@project_form} phx-submit="create_project" class="mt-2 space-y-2 px-1">
                    <.input field={@project_form[:name]} placeholder="Name" required />
                    <.input field={@project_form[:description]} placeholder="Description (optional)" />
                    <button type="submit" class="btn btn-secondary btn-sm w-full">
                      Create project
                    </button>
                  </.form>
                </details>
              </div>
            </aside>

            <%!-- Reader / editor --%>
            <section class="card panel-card border border-base-300 lg:max-h-[calc(100vh-8rem)] lg:overflow-y-auto">
              <div class="flex justify-end border-b border-base-300 px-2 py-1.5">
                <div class="join">
                  <button
                    type="button"
                    phx-click="toggle_view"
                    phx-value-mode="reader"
                    class={[
                      "btn btn-ghost btn-xs join-item h-8 w-8 p-0",
                      @view_mode == "reader" && "btn-active"
                    ]}
                    aria-label="List view"
                    title="List view"
                  >
                    <.icon name="hero-list-bullet" class="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_view"
                    phx-value-mode="graph"
                    class={[
                      "btn btn-ghost btn-xs join-item h-8 w-8 p-0",
                      @view_mode == "graph" && "btn-active"
                    ]}
                    aria-label="Graph view"
                    title="Graph view"
                  >
                    <.icon name="hero-share" class="h-4 w-4" />
                  </button>
                </div>
              </div>

              <%!-- Graph view --%>
              <div
                :if={@view_mode == "graph"}
                class="relative h-[60vh] text-base-content lg:h-[calc(100vh-8rem)]"
              >
                <div
                  id="kairo-graph"
                  phx-hook="KairoGraph"
                  data-graph={Jason.encode!(@graph)}
                  class="absolute inset-0"
                >
                </div>
                <div class="pointer-events-none absolute bottom-2 left-3 text-xs text-base-content/40">
                  Connected sources share a tag
                </div>
              </div>

              <form
                :if={@view_mode == "reader" and @composing}
                id="kairo-note-form"
                phx-submit="save_note"
                phx-change="compose_change"
                class="card-body space-y-3 p-3 sm:p-4"
              >
                <div class="flex items-center justify-between">
                  <h2 class="card-title text-base sm:text-lg">
                    <%= if @editing_source do %>
                      Edit source
                    <% else %>
                      New note
                    <% end %>
                  </h2>
                  <button type="button" phx-click="cancel_note" class="btn btn-ghost btn-sm">
                    Cancel
                  </button>
                </div>

                <input
                  id="kairo-note-title"
                  type="text"
                  name="note[title]"
                  value={@compose["title"]}
                  placeholder="Title"
                  autocomplete="off"
                  class="input input-bordered w-full font-medium"
                />

                <div class="grid gap-2 sm:grid-cols-2">
                  <select name="note[project_id]" class="select select-bordered select-sm">
                    <option value="" selected={@compose["project_id"] in [nil, ""]}>Inbox</option>
                    <option
                      :for={project <- @projects}
                      value={project.id}
                      selected={to_string(@compose["project_id"]) == to_string(project.id)}
                    >
                      {project.name}
                    </option>
                  </select>
                  <input
                    id="kairo-note-tags"
                    type="text"
                    name="note[tags]"
                    value={@compose["tags"]}
                    placeholder="tags, comma, separated"
                    autocomplete="off"
                    class="input input-bordered input-sm w-full"
                  />
                </div>

                <div role="tablist" class="tabs tabs-bordered">
                  <button
                    type="button"
                    phx-click="set_compose_tab"
                    phx-value-tab="write"
                    class={["tab", @compose_tab == "write" && "tab-active"]}
                  >
                    Write
                  </button>
                  <button
                    type="button"
                    phx-click="set_compose_tab"
                    phx-value-tab="preview"
                    class={["tab", @compose_tab == "preview" && "tab-active"]}
                  >
                    Preview
                  </button>
                </div>

                <textarea
                  :if={is_nil(@editing_source) or !@editing_source.encrypted}
                  id={"kairo-note-content-#{@editing_source_id || "new"}"}
                  name="note[content]"
                  rows="16"
                  phx-debounce="200"
                  phx-update="ignore"
                  placeholder="Write markdown…"
                  class={[
                    "textarea textarea-bordered w-full font-mono text-sm",
                    @compose_tab != "write" && "hidden"
                  ]}
                >{@compose["content"]}</textarea>
                <div
                  :if={@editing_source && @editing_source.encrypted}
                  class="rounded border border-warning/30 bg-warning/5 p-3 text-sm text-base-content/70"
                >
                  Encrypted source content cannot be edited on the server. You can still change the
                  title, project, and tags.
                </div>
                <div
                  :if={@compose_tab == "preview"}
                  class="prose min-h-[16rem] max-w-none rounded border border-base-300 bg-base-100 p-3"
                >
                  {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@compose["content"] || ""))}
                </div>

                <label
                  :if={is_nil(@editing_source) && @master_vault}
                  class="flex cursor-pointer items-center gap-2 text-sm text-base-content/70"
                >
                  <input
                    type="checkbox"
                    name="note[encrypt]"
                    value="true"
                    checked={@compose["encrypt"] == "true"}
                    class="checkbox checkbox-xs"
                  /> Encrypt — the server never sees the content
                </label>
                <p class="hidden text-xs text-error" data-kairo-encrypt-error></p>

                <div class="flex justify-end gap-2">
                  <button type="button" phx-click="cancel_note" class="btn btn-ghost btn-sm">
                    Cancel
                  </button>
                  <button
                    :if={@compose["encrypt"] != "true"}
                    type="submit"
                    class="btn btn-primary btn-sm"
                  >
                    {if @editing_source, do: "Save changes", else: "Save note"}
                  </button>
                  <button
                    :if={@compose["encrypt"] == "true"}
                    type="button"
                    data-kairo-encrypt-save
                    class="btn btn-primary btn-sm"
                  >
                    <.icon name="hero-lock-closed" class="h-3.5 w-3.5" /> Save encrypted
                  </button>
                </div>
              </form>

              <div
                :if={@view_mode == "reader" and is_nil(@selected) and not @composing}
                class="flex flex-col items-center justify-center gap-3 p-12 text-center text-base-content/50"
              >
                <.icon name="hero-document-magnifying-glass" class="h-10 w-10" />
                <p class="text-sm">Select a source to read it, or start a new note.</p>
                <button type="button" phx-click="new_note" class="btn btn-outline btn-sm">
                  <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
                </button>
              </div>

              <article
                :if={@view_mode == "reader" and @selected}
                class="card-body space-y-4 p-3 sm:p-4"
              >
                <header class="space-y-2 border-b border-base-300 pb-4">
                  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <h1 class="min-w-0 text-xl font-bold sm:text-2xl">{source_label(@selected)}</h1>
                    <div class="flex shrink-0 items-center gap-2">
                      <button
                        type="button"
                        phx-click="edit_source"
                        phx-value-id={@selected.id}
                        class="btn btn-outline btn-xs"
                      >
                        <.icon name="hero-pencil-square" class="h-3.5 w-3.5" /> Edit
                      </button>
                      <button
                        type="button"
                        phx-click="delete_source"
                        phx-value-id={@selected.id}
                        data-confirm="Delete this Kairo source? This cannot be undone."
                        class="btn btn-error btn-outline btn-xs"
                      >
                        <.icon name="hero-trash" class="h-3.5 w-3.5" /> Delete
                      </button>
                    </div>
                  </div>
                  <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
                    <span :if={@selected.status not in ["stored", "compiled"]} class="badge badge-sm">
                      {@selected.status}
                    </span>
                    <span :if={@selected.encrypted} class="badge badge-warning badge-outline badge-sm">
                      <.icon name="hero-lock-closed" class="h-3 w-3" /> encrypted
                    </span>
                    <span :if={@selected.project}>{@selected.project.name}</span>
                    <span :if={@selected.ingested_at}>{format_datetime(@selected.ingested_at)}</span>
                  </div>
                  <p
                    :if={@selected.status == "failed" && @selected.error_message}
                    class="text-xs text-error"
                  >
                    Fetch failed: {@selected.error_message}
                  </p>
                  <a
                    :if={present_url?(@selected.url)}
                    href={@selected.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link link-primary inline-flex items-center gap-1 text-sm"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
                    {@selected.url}
                  </a>
                  <div :if={@selected.tags not in [nil, []]} class="flex flex-wrap gap-1">
                    <button
                      :for={tag <- @selected.tags}
                      type="button"
                      phx-click="filter_tag"
                      phx-value-tag={tag}
                      class="badge badge-ghost badge-sm cursor-pointer"
                    >
                      #{tag}
                    </button>
                  </div>
                </header>

                <div
                  :if={@selected.encrypted}
                  class="space-y-3 rounded-lg border border-base-300 bg-base-200/40 p-4"
                  data-kairo-reader
                >
                  <p class="text-sm text-base-content/70">
                    This source is encrypted. Decrypt it in this tab to read the content.
                  </p>
                  <button
                    type="button"
                    class="btn btn-outline btn-sm"
                    data-kairo-decrypt
                    data-kairo-payload={Jason.encode!(@selected.encrypted_content)}
                  >
                    <.icon name="hero-lock-open" class="h-4 w-4" /> Decrypt content
                  </button>
                  <pre
                    class="mt-1 hidden max-w-none whitespace-pre-wrap break-words rounded bg-base-100 p-3 text-sm"
                    data-kairo-output
                  ></pre>
                </div>

                <%= if file_url = source_file_url(@selected) do %>
                  <div class="space-y-3 rounded-lg border border-base-300 bg-base-200/30 p-3">
                    <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                      <div class="flex min-w-0 items-center gap-2 text-sm">
                        <.icon name={source_icon(@selected)} class="h-4 w-4 shrink-0" />
                        <span class="min-w-0 truncate font-medium">
                          {source_file_name(@selected)}
                        </span>
                        <span
                          :if={format_file_size(source_file_size(@selected))}
                          class="text-xs text-base-content/50"
                        >
                          {format_file_size(source_file_size(@selected))}
                        </span>
                      </div>
                      <a
                        href={file_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-outline btn-xs"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5" /> Open
                      </a>
                    </div>
                    <img
                      :if={source_image?(@selected)}
                      src={file_url}
                      alt={source_file_name(@selected)}
                      class="max-h-[70vh] w-full rounded border border-base-300 object-contain"
                    />
                    <iframe
                      :if={source_pdf?(@selected)}
                      src={file_url}
                      class="h-[70vh] w-full rounded border border-base-300 bg-base-100"
                      title={source_file_name(@selected)}
                    >
                    </iframe>
                  </div>
                <% end %>

                <pre
                  :if={
                    !@selected.encrypted and present?(@selected.content) and
                      preformatted_content?(@selected)
                  }
                  class="max-w-none whitespace-pre-wrap break-words rounded border border-base-300 bg-base-200/30 p-3 text-sm"
                ><%= @selected.content %></pre>

                <div
                  :if={
                    !@selected.encrypted and present?(@selected.content) and
                      !preformatted_content?(@selected)
                  }
                  class="prose max-w-none"
                >
                  {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@selected.content || ""))}
                </div>

                <div :if={@related != []} class="border-t border-base-300 pt-4">
                  <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                    Related (shared tags)
                  </h3>
                  <ul class="space-y-1">
                    <li :for={source <- @related}>
                      <button
                        type="button"
                        phx-click="select_source"
                        phx-value-id={source.id}
                        class="flex w-full items-center gap-1.5 truncate rounded px-2 py-1 text-left text-sm hover:bg-base-300/40"
                      >
                        <.icon
                          name={source_icon(source)}
                          class="h-3.5 w-3.5 shrink-0"
                        />
                        <span class="truncate">{source_label(source)}</span>
                      </button>
                    </li>
                  </ul>
                </div>
              </article>
            </section>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp present_url?(url), do: is_binary(url) and String.trim(url) != ""
end
