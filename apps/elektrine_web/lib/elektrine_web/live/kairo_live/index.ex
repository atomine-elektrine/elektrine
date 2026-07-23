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
        if connected?(socket), do: Phoenix.PubSub.subscribe(Elektrine.PubSub, "kairo:#{user.id}")

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
  def handle_params(params, _uri, socket) do
    selected_id =
      case params do
        %{"s" => id} -> parse_id(id)
        _params -> nil
      end

    {:noreply,
     socket
     |> assign(:selected_id, selected_id)
     |> assign_view()}
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
    {:noreply, socket |> assign(:view_mode, mode) |> assign_view()}
  end

  def handle_event("select_source", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:composing, false)
     |> assign(:view_mode, "reader")
     |> push_patch(to: ~p"/kairo?s=#{id}")}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, "reader")
     |> assign(:composing, true)
     |> assign(:editing_source_id, nil)
     |> assign(:compose, empty_compose())
     |> assign(:compose_tab, "write")
     |> push_patch(to: ~p"/kairo")}
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
        deselecting? = socket.assigns.selected_id == source_id

        socket =
          socket
          |> assign(:composing, false)
          |> assign(:editing_source_id, nil)
          |> maybe_clear_selected(source_id)
          |> put_flash(:info, "Source deleted")
          |> load_kairo(user)

        socket = if deselecting?, do: push_patch(socket, to: ~p"/kairo"), else: socket

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Source could not be deleted")}
    end
  end

  def handle_event("retry_url_fetch", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Kairo.retry_url_source(user, id) do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(:selected_id, source.id)
         |> put_flash(:info, "Link fetch queued again")
         |> load_kairo(user)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Source not found")}

      _error ->
        {:noreply, put_flash(socket, :error, "This source cannot be retried")}
    end
  end

  @impl true
  def handle_info({:kairo_source_updated, _source_id}, socket) do
    {:noreply, load_kairo(socket, socket.assigns.current_user)}
  end

  def handle_info({:storage_updated, _storage}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

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
    sources = Kairo.list_sources(user, limit: socket.assigns.source_limit)
    sources_total = Kairo.count_sources(user)

    socket
    |> assign(:page_title, "Kairo")
    |> assign(:projects, Kairo.list_projects(user))
    |> assign(:sources, sources)
    |> assign(:sources_total, sources_total)
    |> assign(
      :source_cap_reached,
      socket.assigns.source_limit >= @max_sources and sources_total > length(sources)
    )
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
    |> assign(
      :graph,
      if(socket.assigns.view_mode == "graph",
        do: build_graph(visible, socket.assigns.projects),
        else: empty_graph()
      )
    )
  end

  # Palette for project-colored source nodes. Inbox (no project) falls back to a
  # neutral gray. Mid-tone hues so they read on both light and dark themes.
  @project_palette ~w(#6366f1 #ec4899 #14b8a6 #f59e0b #8b5cf6 #ef4444 #10b981 #3b82f6)
  @inbox_color "#9ca3af"

  # Cap on how many of its strongest neighbors each source links to. Keeps the
  # graph sparse and readable (and cheap to animate) even when many sources share
  # a common tag, which would otherwise produce a near-complete graph.
  @max_edges_per_source 5
  @max_graph_sources 200

  defp empty_graph, do: %{nodes: [], edges: [], total: 0, truncated: false}

  # Graph: one node per source (file), with an edge between two
  # sources that share tags. Edge weight is the number of shared tags. To avoid a
  # hairball, each source only links to its strongest few neighbors. Sources are
  # colored by project; untagged or unconnected sources appear as lone nodes.
  defp build_graph(sources, projects) do
    total = length(sources)
    sources = Enum.take(sources, @max_graph_sources)
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

    %{nodes: nodes, edges: edges, total: total, truncated: total > length(sources)}
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

  # data-confirm text for actions that would silently replace an in-progress
  # note; nil (no confirm) when nothing would be lost.
  defp discard_note_confirm(false, _editing_source_id, _compose), do: nil

  defp discard_note_confirm(true, editing_source_id, compose) do
    if editing_source_id != nil or present?(compose["title"]) or present?(compose["content"]) do
      "Discard your unsaved changes?"
    end
  end

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
    <div class="mx-auto w-full max-w-7xl px-4 pb-4 sm:px-6 lg:px-8">
      <section class="flex flex-col gap-4 lg:gap-5">
        <.e_nav
          active_tab="kairo"
          current_user={@current_user}
          badge_counts={@e_nav_badge_counts}
          class="mb-0"
        />

        <div
          id="kairo-vault"
          phx-hook="KairoVault"
          data-kairo-master-configured={to_string(not is_nil(@master_vault))}
          data-kairo-master-wrapped-dek={@master_vault && Jason.encode!(@master_vault.wrapped_dek)}
        >
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-[17.5rem_minmax(0,1fr)] lg:items-start lg:gap-5">
            <%!-- Library sidebar: sticky chrome, only the list scrolls --%>
            <aside class="card panel-card app-sticky-sidebar flex max-h-[min(32rem,70dvh)] flex-col overflow-hidden border border-base-300 lg:max-h-[calc(100dvh-9rem)]">
              <header class="shrink-0 space-y-2.5 border-b border-base-300 p-3">
                <div class="flex items-center gap-1.5">
                  <.button
                    type="button"
                    phx-click="new_note"
                    data-confirm={discard_note_confirm(@composing, @editing_source_id, @compose)}
                    size="sm"
                    class="min-w-0 flex-1 justify-center"
                  >
                    <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
                  </.button>
                  <label
                    for={@uploads.kairo_files.ref}
                    class="btn btn-outline btn-sm h-9 min-h-9 w-9 shrink-0 p-0"
                    title="Upload file"
                    aria-label="Upload file"
                  >
                    <.icon name="hero-arrow-up-tray" class="h-4 w-4" />
                  </label>
                  <button
                    type="button"
                    phx-click="toggle_add_link"
                    class={[
                      "btn btn-sm h-9 min-h-9 w-9 shrink-0 p-0",
                      if(@adding_link, do: "btn-primary", else: "btn-outline")
                    ]}
                    title="Save a link"
                    aria-label="Save a link"
                    aria-pressed={to_string(@adding_link)}
                  >
                    <.icon name="hero-link" class="h-4 w-4" />
                  </button>
                </div>

                <form
                  id="kairo-upload-form"
                  phx-change="validate_kairo_upload"
                  phx-submit="upload_kairo_files"
                  class={@uploads.kairo_files.entries != [] && "space-y-1.5"}
                >
                  <div class="sr-only">
                    <.live_file_input upload={@uploads.kairo_files} />
                  </div>

                  <div
                    :if={@uploads.kairo_files.entries != []}
                    class="space-y-1.5 rounded-lg border border-base-300 bg-base-200/40 p-2"
                  >
                    <div class="space-y-1">
                      <div
                        :for={entry <- @uploads.kairo_files.entries}
                        class="flex items-center gap-2 rounded-md bg-base-100 px-2 py-1 text-xs"
                      >
                        <.icon name="hero-paper-clip" class="h-3.5 w-3.5 shrink-0" />
                        <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
                        <span class="text-base-content/50">{entry.progress}%</span>
                        <.button
                          type="button"
                          phx-click="cancel_kairo_upload"
                          phx-value-ref={entry.ref}
                          variant="ghost"
                          size="xs"
                          class="h-6 min-h-0 w-6 p-0"
                          aria-label="Remove file"
                        >
                          <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
                        </.button>
                      </div>
                    </div>
                    <div class="grid grid-cols-2 gap-1.5">
                      <select name="upload[project_id]" class="select select-bordered select-sm">
                        <option value="">Inbox</option>
                        <option :for={project <- @projects} value={project.id}>
                          {project.name}
                        </option>
                      </select>
                      <input
                        type="text"
                        name="upload[tags]"
                        placeholder="tags"
                        autocomplete="off"
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <.button type="submit" variant="secondary" size="sm" class="w-full">
                      Save files
                    </.button>
                  </div>

                  <p
                    :for={error <- upload_errors(@uploads.kairo_files)}
                    class="text-xs text-error"
                  >
                    {upload_error_text(error)}
                  </p>
                </form>

                <form
                  :if={@adding_link}
                  phx-submit="save_link"
                  class="space-y-1.5 rounded-lg border border-base-300 bg-base-200/40 p-2"
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
                    placeholder="Title (optional)"
                    autocomplete="off"
                    class="input input-bordered input-sm w-full"
                  />
                  <div class="grid grid-cols-2 gap-1.5">
                    <select name="link[project_id]" class="select select-bordered select-sm">
                      <option value="">Inbox</option>
                      <option :for={project <- @projects} value={project.id}>{project.name}</option>
                    </select>
                    <input
                      type="text"
                      name="link[tags]"
                      placeholder="tags"
                      autocomplete="off"
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <.button type="submit" variant="secondary" size="sm" class="w-full">
                    Save link
                  </.button>
                </form>

                <form id="kairo-search-form" phx-change="search" phx-submit="search">
                  <label class="input input-bordered input-sm flex w-full items-center gap-2">
                    <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-60" />
                    <input
                      id="kairo-search"
                      type="text"
                      name="query"
                      value={@query}
                      placeholder="Search…"
                      autocomplete="off"
                      phx-debounce="150"
                      aria-label="Search sources"
                      class="min-w-0 grow bg-transparent"
                    />
                    <button
                      :if={@query != ""}
                      type="button"
                      phx-click="clear_search"
                      aria-label="Clear search"
                      class="text-base-content/50 hover:text-base-content"
                    >
                      <.icon name="hero-x-mark" class="h-4 w-4" />
                    </button>
                  </label>
                </form>

                <div
                  :if={@has_encrypted_sources || @composing}
                  class="hidden flex-col gap-1.5 rounded-lg border border-warning/30 bg-warning/5 p-2"
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
                    <.button
                      type="button"
                      variant="default"
                      outline
                      size="xs"
                      class="w-full"
                      data-kairo-master-unlock
                    >
                      Unlock vault
                    </.button>
                  <% else %>
                    <span class="text-xs text-warning">
                      <.link navigate={~p"/account/encrypted-data"} class="link">
                        Set up encryption
                      </.link>
                      to decrypt
                    </span>
                  <% end %>
                </div>
                <p
                  class="hidden text-xs text-error"
                  role="alert"
                  aria-live="polite"
                  data-kairo-master-error
                >
                </p>

                <details
                  :if={@projects != [] or @all_tags != []}
                  class="group rounded-lg border border-base-300/80 bg-base-200/25"
                  open={@active_project != nil or @active_tag != nil}
                >
                  <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-2.5 py-1.5 text-xs font-medium text-base-content/70 marker:content-none [&::-webkit-details-marker]:hidden">
                    <span class="flex min-w-0 items-center gap-1.5">
                      <.icon name="hero-funnel" class="h-3.5 w-3.5 shrink-0" />
                      <span class="truncate">
                        <%= cond do %>
                          <% @active_project_record -> %>
                            {@active_project_record.name}
                          <% @active_project == :inbox -> %>
                            Inbox
                          <% @active_tag -> %>
                            #{@active_tag}
                          <% true -> %>
                            Filters
                        <% end %>
                      </span>
                    </span>
                    <.icon
                      name="hero-chevron-down"
                      class="h-3.5 w-3.5 shrink-0 transition-transform group-open:rotate-180"
                    />
                  </summary>

                  <div class="space-y-2 border-t border-base-300/70 px-2.5 py-2">
                    <div :if={@projects != []} class="space-y-1.5">
                      <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/45">
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
                            if(@active_project == project.id,
                              do: "badge-primary",
                              else: "badge-outline"
                            ),
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

                      <div
                        :if={@active_project_record}
                        class="space-y-1.5 rounded-md border border-base-300 bg-base-100/70 p-1.5"
                      >
                        <form phx-submit="rename_project" class="flex gap-1">
                          <input type="hidden" name="project[id]" value={@active_project_record.id} />
                          <input
                            type="text"
                            name="project[name]"
                            value={@active_project_record.name}
                            required
                            class="input input-bordered input-xs min-w-0 flex-1"
                          />
                          <.button type="submit" variant="default" outline size="xs" title="Rename">
                            <.icon name="hero-check" class="h-3 w-3" />
                          </.button>
                        </form>
                        <div class="flex gap-1">
                          <.button
                            type="button"
                            phx-click="toggle_archive_project"
                            phx-value-id={@active_project_record.id}
                            variant="default"
                            outline
                            size="xs"
                            class="flex-1"
                          >
                            {if @active_project_record.status == "archived",
                              do: "Unarchive",
                              else: "Archive"}
                          </.button>
                          <.button
                            type="button"
                            phx-click="delete_project"
                            phx-value-id={@active_project_record.id}
                            data-confirm="Delete this project? Its sources will move to the inbox."
                            variant="error"
                            outline
                            size="xs"
                            class="flex-1"
                          >
                            Delete
                          </.button>
                        </div>
                      </div>
                    </div>

                    <div :if={@all_tags != []} class="space-y-1.5">
                      <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/45">
                        Tags
                      </p>
                      <div class="flex max-h-20 flex-wrap gap-1 overflow-y-auto">
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
                </details>
              </header>

              <nav class="min-h-0 flex-1 space-y-1 overflow-y-auto overscroll-contain p-2">
                <p
                  :if={@visible_count == 0}
                  class="px-2 py-6 text-center text-sm text-base-content/55"
                >
                  <%= if @sources == [] do %>
                    No sources yet. Capture a note, file, or link.
                  <% else %>
                    No matching sources.
                  <% end %>
                </p>

                <details :for={folder <- @folders} open class="group">
                  <summary class="flex cursor-pointer items-center justify-between rounded-lg px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/55 hover:bg-base-300/40">
                    <span class="flex min-w-0 items-center gap-1">
                      <.icon
                        name="hero-chevron-right"
                        class="h-3 w-3 shrink-0 transition-transform group-open:rotate-90"
                      />
                      <span class="truncate">{folder.name}</span>
                    </span>
                    <span class="shrink-0 opacity-60">{length(folder.sources)}</span>
                  </summary>
                  <ul class="mt-0.5 space-y-0.5">
                    <li :for={source <- folder.sources}>
                      <button
                        type="button"
                        phx-click="select_source"
                        phx-value-id={source.id}
                        data-confirm={discard_note_confirm(@composing, @editing_source_id, @compose)}
                        class={[
                          "flex w-full items-center gap-1.5 truncate rounded-lg px-2 py-1.5 text-left text-sm",
                          if(@selected && @selected.id == source.id,
                            do: "bg-primary/15 font-medium text-primary",
                            else: "hover:bg-base-300/40"
                          )
                        ]}
                      >
                        <.icon name={source_icon(source)} class="h-4 w-4 shrink-0 opacity-80" />
                        <span class="truncate">{source_label(source)}</span>
                        <span
                          :if={source.source_type == "url" and source.status == "received"}
                          class="loading loading-spinner loading-xs ml-auto shrink-0 opacity-50"
                          title="Fetching content"
                        >
                        </span>
                        <.icon
                          :if={source.status == "failed"}
                          name="hero-exclamation-triangle"
                          class="ml-auto h-3.5 w-3.5 shrink-0 text-error"
                          title="Fetch failed"
                        />
                        <.icon
                          :if={source.encrypted}
                          name="hero-lock-closed"
                          class="ml-auto h-3 w-3 shrink-0 text-warning opacity-80"
                          title="Encrypted"
                        />
                      </button>
                    </li>
                  </ul>
                </details>

                <.button
                  :if={length(@sources) < @sources_total and not @source_cap_reached}
                  type="button"
                  phx-click="load_more"
                  variant="default"
                  size="xs"
                  class="w-full load-more-button"
                >
                  Load more ({length(@sources)} of {@sources_total} loaded)
                </.button>
                <p :if={@source_cap_reached} class="px-2 py-2 text-xs text-base-content/50">
                  Showing the newest {length(@sources)} of {@sources_total} sources. Use the API for
                  deeper pagination.
                </p>
              </nav>

              <div class="shrink-0 border-t border-base-300 p-2">
                <details class="group">
                  <summary class="flex cursor-pointer items-center gap-1 rounded-lg px-2 py-1.5 text-xs text-base-content/65 hover:bg-base-300/40">
                    <.icon name="hero-folder-plus" class="h-3.5 w-3.5" /> New project
                  </summary>
                  <.form
                    for={@project_form}
                    phx-submit="create_project"
                    class="mt-1.5 space-y-1.5 px-1"
                  >
                    <input
                      type="text"
                      name={@project_form[:name].name}
                      id={@project_form[:name].id}
                      value={@project_form[:name].value}
                      placeholder="Name"
                      required
                      class="input input-bordered input-sm w-full"
                    />
                    <input
                      type="text"
                      name={@project_form[:description].name}
                      id={@project_form[:description].id}
                      value={@project_form[:description].value}
                      placeholder="Description (optional)"
                      class="input input-bordered input-sm w-full"
                    />
                    <.button type="submit" variant="secondary" size="sm" class="w-full">
                      Create project
                    </.button>
                  </.form>
                </details>
              </div>
            </aside>

            <%!-- Reader / editor --%>
            <section class="card panel-card flex flex-col overflow-hidden border border-base-300 lg:max-h-[calc(100dvh-9rem)]">
              <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-base-content/80">
                    <%= cond do %>
                      <% @composing && @editing_source -> %>
                        Editing
                      <% @composing -> %>
                        New note
                      <% @selected -> %>
                        {source_label(@selected)}
                      <% @view_mode == "graph" -> %>
                        Graph
                      <% true -> %>
                        Reader
                    <% end %>
                  </p>
                </div>
                <div class="join shrink-0">
                  <button
                    type="button"
                    phx-click="toggle_view"
                    phx-value-mode="reader"
                    class={[
                      "btn btn-ghost btn-xs join-item h-8 w-8 p-0",
                      @view_mode == "reader" && "btn-active"
                    ]}
                    aria-label="Reader view"
                    aria-pressed={to_string(@view_mode == "reader")}
                    title="Reader view"
                  >
                    <.icon name="hero-document-text" class="h-4 w-4" />
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
                    aria-pressed={to_string(@view_mode == "graph")}
                    title="Graph view"
                  >
                    <.icon name="hero-share" class="h-4 w-4" />
                  </button>
                </div>
              </div>

              <%!-- Graph view --%>
              <div
                :if={@view_mode == "graph"}
                class="relative h-[min(28rem,60dvh)] text-base-content"
              >
                <div
                  id="kairo-graph"
                  phx-hook="KairoGraph"
                  data-graph={Jason.encode!(@graph)}
                  class="absolute inset-0"
                >
                </div>
                <div class="pointer-events-none absolute bottom-2 left-3 text-xs text-base-content/40">
                  <%= if @graph.truncated do %>
                    Showing {length(@graph.nodes)} of {@graph.total} sources · connected sources share a tag
                  <% else %>
                    Connected sources share a tag
                  <% end %>
                </div>
              </div>

              <form
                :if={@view_mode == "reader" and @composing}
                id="kairo-note-form"
                phx-submit="save_note"
                phx-change="compose_change"
                class="flex min-h-0 flex-col lg:max-h-[calc(100dvh-12rem)]"
              >
                <div class="min-h-0 space-y-2.5 overflow-y-auto overscroll-contain p-3 sm:p-4">
                  <input
                    id="kairo-note-title"
                    type="text"
                    name="note[title]"
                    value={@compose["title"]}
                    placeholder="Title"
                    autocomplete="off"
                    phx-mounted={JS.focus()}
                    class="input input-bordered input-sm w-full text-base font-semibold"
                  />

                  <div class="grid gap-1.5 sm:grid-cols-2">
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

                  <div class="inline-flex rounded-lg border border-base-300 p-0.5" role="tablist">
                    <button
                      type="button"
                      role="tab"
                      aria-selected={to_string(@compose_tab == "write")}
                      phx-click="set_compose_tab"
                      phx-value-tab="write"
                      class={[
                        "btn btn-xs rounded-md",
                        if(@compose_tab == "write", do: "btn-active", else: "btn-ghost")
                      ]}
                    >
                      Write
                    </button>
                    <button
                      type="button"
                      role="tab"
                      aria-selected={to_string(@compose_tab == "preview")}
                      phx-click="set_compose_tab"
                      phx-value-tab="preview"
                      class={[
                        "btn btn-xs rounded-md",
                        if(@compose_tab == "preview", do: "btn-active", else: "btn-ghost")
                      ]}
                    >
                      Preview
                    </button>
                  </div>

                  <textarea
                    :if={is_nil(@editing_source) or !@editing_source.encrypted}
                    id={"kairo-note-content-#{@editing_source_id || "new"}"}
                    name="note[content]"
                    rows="14"
                    phx-debounce="200"
                    phx-update="ignore"
                    placeholder="Write markdown…"
                    class={[
                      "textarea textarea-bordered min-h-[14rem] w-full flex-1 font-mono text-sm leading-relaxed",
                      @compose_tab != "write" && "hidden"
                    ]}
                  >{@compose["content"]}</textarea>
                  <div
                    :if={@editing_source && @editing_source.encrypted}
                    class="rounded-lg border border-warning/30 bg-warning/5 p-3 text-sm text-base-content/70"
                  >
                    Encrypted source content cannot be edited on the server. You can still change the
                    title, project, and tags.
                  </div>
                  <div
                    :if={@compose_tab == "preview"}
                    class="prose min-h-[14rem] max-w-none rounded-lg border border-base-300 bg-base-100 p-3"
                  >
                    {Phoenix.HTML.raw(Elektrine.Markdown.to_html(@compose["content"] || ""))}
                  </div>

                  <label
                    :if={is_nil(@editing_source) && @master_vault}
                    class="flex cursor-pointer items-center gap-1.5 text-sm text-base-content/70"
                  >
                    <input
                      type="checkbox"
                      name="note[encrypt]"
                      value="true"
                      checked={@compose["encrypt"] == "true"}
                      class="checkbox checkbox-xs"
                    /> Encrypt — the server never sees the content
                  </label>
                  <p
                    class="hidden text-xs text-error"
                    role="alert"
                    aria-live="polite"
                    data-kairo-encrypt-error
                  >
                  </p>
                </div>

                <div class="flex shrink-0 items-center justify-end gap-1.5 border-t border-base-300 bg-base-200/20 px-3 py-2.5 sm:px-4">
                  <.button type="button" phx-click="cancel_note" variant="ghost" size="sm">
                    Cancel
                  </.button>
                  <.button :if={@compose["encrypt"] != "true"} type="submit" size="sm">
                    {if @editing_source, do: "Save changes", else: "Save note"}
                  </.button>
                  <.button
                    :if={@compose["encrypt"] == "true"}
                    type="button"
                    data-kairo-encrypt-save
                    size="sm"
                  >
                    <.icon name="hero-lock-closed" class="h-3.5 w-3.5" /> Save encrypted
                  </.button>
                </div>
              </form>

              <div
                :if={@view_mode == "reader" and is_nil(@selected) and not @composing}
                class="flex flex-col items-center justify-center gap-3 px-6 py-10 text-center text-base-content/50 sm:py-12"
              >
                <.icon name="hero-document-magnifying-glass" class="h-10 w-10 opacity-70" />
                <div class="space-y-1">
                  <p class="text-sm font-medium text-base-content/70">Nothing selected</p>
                  <p class="max-w-xs text-sm">
                    Pick a source from the library, or start a new note.
                  </p>
                </div>
                <.button
                  type="button"
                  phx-click="new_note"
                  data-confirm={discard_note_confirm(@composing, @editing_source_id, @compose)}
                  variant="default"
                  outline
                  size="sm"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4" /> New note
                </.button>
              </div>

              <article
                :if={@view_mode == "reader" and not @composing and @selected}
                class="flex min-h-0 flex-col overflow-hidden lg:max-h-[calc(100dvh-12rem)]"
              >
                <header class="shrink-0 space-y-2 border-b border-base-300 px-3 py-3 sm:px-4">
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <h1 class="min-w-0 text-xl font-bold tracking-tight sm:text-2xl">
                      {source_label(@selected)}
                    </h1>
                    <div class="flex shrink-0 items-center gap-1.5">
                      <.button
                        type="button"
                        phx-click="edit_source"
                        phx-value-id={@selected.id}
                        variant="default"
                        outline
                        size="xs"
                      >
                        <.icon name="hero-pencil-square" class="h-3.5 w-3.5" /> Edit
                      </.button>
                      <.button
                        type="button"
                        phx-click="delete_source"
                        phx-value-id={@selected.id}
                        data-confirm="Delete this Kairo source? This cannot be undone."
                        variant="error"
                        outline
                        size="xs"
                      >
                        <.icon name="hero-trash" class="h-3.5 w-3.5" /> Delete
                      </.button>
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
                  <.button
                    :if={
                      @selected.source_type == "url" and @selected.status == "failed" and
                        not @selected.encrypted
                    }
                    type="button"
                    phx-click="retry_url_fetch"
                    phx-value-id={@selected.id}
                    variant="default"
                    outline
                    size="xs"
                  >
                    <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Retry fetch
                  </.button>
                  <%= if source_url = safe_http_url(@selected.url) do %>
                    <a
                      href={source_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-primary inline-flex items-center gap-1 break-all text-sm"
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4 shrink-0" />
                      {source_url}
                    </a>
                  <% end %>
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
                  id={"kairo-reader-scroll-#{@selected.id}"}
                  class="min-h-0 flex-1 space-y-4 overflow-y-auto overscroll-contain px-3 py-4 sm:px-4"
                >
                  <div
                    :if={@selected.encrypted}
                    class="space-y-3 rounded-lg border border-base-300 bg-base-200/40 p-4"
                    data-kairo-reader
                  >
                    <p class="text-sm text-base-content/70">
                      This source is encrypted. Decrypt it in this tab to read the content.
                    </p>
                    <.button
                      type="button"
                      variant="default"
                      outline
                      size="sm"
                      data-kairo-decrypt
                      data-kairo-payload={Jason.encode!(@selected.encrypted_content)}
                    >
                      <.icon name="hero-lock-open" class="h-4 w-4" /> Decrypt content
                    </.button>
                    <pre
                      class="mt-1 hidden max-w-none whitespace-pre-wrap break-words rounded-lg bg-base-100 p-3 text-sm"
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
                        <.button
                          href={file_url}
                          target="_blank"
                          rel="noopener noreferrer"
                          variant="default"
                          outline
                          size="xs"
                        >
                          <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5" /> Open
                        </.button>
                      </div>
                      <img
                        :if={source_image?(@selected)}
                        src={file_url}
                        alt={source_file_name(@selected)}
                        class="max-h-[70vh] w-full rounded-lg border border-base-300 object-contain"
                      />
                      <iframe
                        :if={source_pdf?(@selected)}
                        src={file_url}
                        class="h-[70vh] w-full rounded-lg border border-base-300 bg-base-100"
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
                    class="max-w-none whitespace-pre-wrap break-words rounded-lg border border-base-300 bg-base-200/30 p-3 text-sm"
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
                          class="flex w-full items-center gap-1.5 truncate rounded-lg px-2 py-1 text-left text-sm hover:bg-base-300/40"
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
                </div>
              </article>
            </section>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # Sources can also arrive through API and MCP clients, so browser-native URL
  # inputs are not a sufficient safety boundary. Never turn non-web schemes into
  # clickable links, even if malformed existing data is present in the database.
  defp safe_http_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if String.downcase(scheme) in ["http", "https"], do: url

      _other ->
        nil
    end
  end

  defp safe_http_url(_url), do: nil
end
