defmodule Kairo.UrlFetchWorker do
  @moduledoc """
  Hydrates a `url` source: fetches the page through the SSRF-safe HTTP stack,
  extracts a title and readable text, and advances the source through
  `received -> processing -> compiled` (or `failed`).

  Zero-knowledge and already-hydrated sources are never touched.
  """

  use Oban.Worker,
    queue: :kairo,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query, only: [from: 2]

  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator
  alias Kairo.Source

  @user_agent "Elektrine/1.0 (Kairo Ingest)"
  @max_body_bytes 5 * 1024 * 1024
  @max_redirects 3
  @max_content_chars 200_000
  @html_types ~w(text/html application/xhtml+xml)
  @text_types ~w(text/plain text/markdown)
  @redirect_statuses [301, 302, 303, 307, 308]
  @claim_fields [
    :project_id,
    :source_type,
    :title,
    :url,
    :content,
    :content_format,
    :content_encrypted,
    :encrypted,
    :encrypted_content,
    :status,
    :tags,
    :metadata,
    :raw_hash,
    :error_message,
    :ingested_at,
    :processed_at,
    :updated_at
  ]

  def enqueue(%Source{id: id, user_id: user_id}) do
    %{"source_id" => id, "user_id" => user_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "user_id" => user_id}}) do
    case Kairo.get_source(user_id, source_id) do
      nil ->
        {:discard, :source_not_found}

      %Source{encrypted: true} ->
        {:discard, :encrypted_source}

      %Source{} = source ->
        if hydratable?(source) do
          hydrate(source)
        else
          {:discard, :nothing_to_fetch}
        end
    end
  end

  defp hydratable?(source) do
    source.source_type == "url" and is_binary(source.url) and
      source.status in ["received", "processing", "failed"] and
      is_nil(source.content_encrypted) and
      (is_nil(source.content) or String.trim(source.content) == "")
  end

  defp hydrate(source) do
    case transition(source, %{"status" => "processing"}) do
      {:ok, claimed} -> fetch_and_finalize(claimed)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp fetch_and_finalize(source) do
    case fetch(source.url) do
      {:ok, page} ->
        finalize_success(source, page)

      {:error, reason, retry} ->
        finalize_failure(source, reason, retry)
    end
  end

  # Fetches happen outside a database transaction. Lock and re-read the row
  # before the terminal write so an edit, encryption change, or deletion made
  # while the request was in flight always wins over the fetched response.
  defp finalize_success(source, page) do
    case transition_if_unchanged(source, fn current ->
           %{
             "status" => "compiled",
             "title" => current.title || page.title,
             "content" => page.content,
             "content_format" => page.content_format,
             "metadata" =>
               Map.merge(current.metadata || %{}, %{
                 "fetched_url" => page.final_url,
                 "fetched_content_type" => page.content_type
               }),
             "error_message" => nil,
             "processed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
           }
         end) do
      {:ok, updated} ->
        update_storage(updated)
        broadcast_update(updated)
        :ok

      {:discard, reason} ->
        {:discard, reason}

      {:retry, reason} ->
        {:error, reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp finalize_failure(source, reason, retry) do
    case transition_if_unchanged(source, fn _current ->
           %{
             "status" => "failed",
             "error_message" => format_error(reason)
           }
         end) do
      {:ok, updated} ->
        update_storage(updated)
        broadcast_update(updated)

        case retry do
          :retry -> {:error, reason}
          :discard -> {:discard, reason}
        end

      {:discard, changed_reason} ->
        {:discard, changed_reason}

      {:retry, changed_reason} ->
        {:error, changed_reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp transition_if_unchanged(source, attrs_fun) do
    Elektrine.Repo.transaction(fn ->
      current =
        Elektrine.Repo.one(
          from current in Source,
            where: current.id == ^source.id and current.user_id == ^source.user_id,
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          Elektrine.Repo.rollback(:source_not_found)

        not same_claim?(source, current) ->
          reason = if hydratable?(current), do: :source_changed_retryable, else: :source_changed
          Elektrine.Repo.rollback(reason)

        true ->
          case transition(current, attrs_fun.(current)) do
            {:ok, updated} -> updated
            {:error, changeset} -> Elektrine.Repo.rollback({:transition_failed, changeset})
          end
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} when reason in [:source_not_found, :source_changed] -> {:discard, reason}
      {:error, :source_changed_retryable} -> {:retry, :source_changed}
      {:error, {:transition_failed, changeset}} -> {:error, changeset}
    end
  end

  defp same_claim?(claimed, current) do
    Enum.all?(@claim_fields, fn field -> Map.get(claimed, field) == Map.get(current, field) end)
  end

  defp update_storage(%Source{user_id: user_id}) do
    _ = Elektrine.Accounts.Storage.update_user_storage(user_id)
    :ok
  end

  defp broadcast_update(%Source{id: source_id, user_id: user_id}) do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "kairo:#{user_id}",
      {:kairo_source_updated, source_id}
    )
  end

  # Status/content updates bypass Kairo.update_source on purpose: the worker is
  # not acting on user-supplied attrs and must be able to write error_message
  # and processed_at directly. The changeset still re-hashes and re-encrypts.
  defp transition(source, attrs) do
    case source |> Source.changeset(attrs) |> Elektrine.Repo.update() do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        # Duplicate compiled content collides with the dedup index; keep the
        # source but mark why it could not be stored.
        if attrs["status"] == "compiled" do
          transition(source, %{
            "status" => "failed",
            "error_message" => "fetched content duplicates an existing source"
          })
        else
          {:error, changeset}
        end
    end
  end

  # The fetch function is overridable so tests can exercise the pipeline
  # without network access.
  defp fetch(url) do
    result =
      case Application.get_env(:elektrine, :kairo_url_fetch_fun) do
        fun when is_function(fun, 1) -> fun.(url)
        nil -> fetch_remote(url, @max_redirects)
      end

    validate_fetch_result(result)
  rescue
    error -> {:error, {:fetch_exception, Exception.message(error)}, :retry}
  end

  defp fetch_remote(url, redirects_left) do
    with {:ok, safe_url} <- validate_url(url) do
      request = Finch.build(:get, safe_url, [{"user-agent", @user_agent}])

      case request(request) do
        {:ok, %{status: 200, body: body, headers: headers}} ->
          build_page(safe_url, body, content_type(headers))

        {:ok, %{status: status, headers: headers}} when status in @redirect_statuses ->
          follow_redirect(headers, safe_url, redirects_left)

        {:ok, %{status: status}} when status in [408, 425, 429] ->
          {:error, {:http_error, status}, :retry}

        {:ok, %{status: status}} when status in 400..499 ->
          {:error, {:http_error, status}, :discard}

        {:ok, %{status: status}} when status in 500..599 ->
          {:error, {:http_error, status}, :retry}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}, :discard}

        {:error, :too_large} ->
          {:error, :too_large, :discard}

        {:error, reason} ->
          {:error, reason, :retry}
      end
    end
  end

  defp request(request) do
    case Application.get_env(:elektrine, :kairo_url_request_fun) do
      fun when is_function(fun, 1) ->
        fun.(request)

      nil ->
        SafeFetch.request(request, Elektrine.Finch,
          receive_timeout: 30_000,
          max_body_bytes: @max_body_bytes
        )
    end
  end

  defp follow_redirect(_headers, _current_url, 0), do: {:error, :too_many_redirects, :discard}

  defp follow_redirect(headers, current_url, redirects_left) do
    case header(headers, "location") do
      nil ->
        {:error, :redirect_without_location, :discard}

      location ->
        follow_redirect_location(location, current_url, redirects_left)
    end
  end

  defp follow_redirect_location(location, current_url, redirects_left) do
    current_url
    |> URI.merge(location)
    |> URI.to_string()
    |> fetch_remote(redirects_left - 1)
  rescue
    _error -> {:error, :invalid_redirect_location, :discard}
  end

  defp validate_url(url) do
    case URLValidator.validate(url) do
      :ok -> {:ok, url}
      {:error, reason} -> {:error, {:unsafe_url, reason}, :discard}
    end
  end

  defp build_page(_final_url, body, _content_type)
       when not is_binary(body),
       do: {:error, :invalid_utf8, :discard}

  defp build_page(final_url, body, content_type) do
    if String.valid?(body) do
      build_utf8_page(final_url, body, content_type)
    else
      {:error, :invalid_utf8, :discard}
    end
  end

  defp build_utf8_page(final_url, body, content_type) do
    cond do
      content_type in @html_types ->
        {title, text} = extract_html(body)

        if String.trim(text) == "" and is_nil(title) do
          {:error, :no_readable_content, :discard}
        else
          {:ok,
           %{
             final_url: final_url,
             content_type: content_type,
             title: title,
             content: truncate(text),
             content_format: "text"
           }}
        end

      content_type in @text_types ->
        {:ok,
         %{
           final_url: final_url,
           content_type: content_type,
           title: nil,
           content: truncate(body),
           content_format: if(content_type == "text/markdown", do: "markdown", else: "text")
         }}

      true ->
        {:error, {:unsupported_content_type, content_type}, :discard}
    end
  end

  defp validate_fetch_result({:ok, page} = result) when is_map(page) do
    values = [
      page[:title],
      page[:content],
      page[:final_url],
      page[:content_type],
      page[:content_format]
    ]

    if Enum.all?(values, fn
         nil -> true
         value when is_binary(value) -> String.valid?(value)
         _value -> false
       end) do
      result
    else
      {:error, :invalid_utf8, :discard}
    end
  end

  defp validate_fetch_result(result), do: result

  @doc """
  Extracts `{title, readable_text}` from an HTML document. Public so the
  extraction heuristics can be tested without the fetch pipeline.
  """
  def extract_html(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        {extract_title(document), extract_text(document)}

      {:error, _reason} ->
        {nil, ""}
    end
  end

  defp extract_title(document) do
    og_title =
      document
      |> Floki.attribute("meta[property='og:title']", "content")
      |> List.first()

    title =
      document
      |> Floki.find("head title")
      |> Floki.text()

    [og_title, title]
    |> Enum.map(&normalize_space/1)
    |> Enum.find(&(&1 != ""))
  end

  defp extract_text(document) do
    cleaned =
      Floki.filter_out(
        document,
        "script, style, noscript, template, svg, nav, header, footer, aside, form"
      )

    main =
      Enum.find_value(["article", "main", "[role=main]", "body"], fn selector ->
        case Floki.find(cleaned, selector) do
          [] -> nil
          nodes -> nodes
        end
      end) || cleaned

    main
    |> Floki.text(sep: "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp normalize_space(nil), do: ""
  defp normalize_space(value), do: value |> String.replace(~r/\s+/, " ") |> String.trim()

  defp truncate(text) when byte_size(text) <= @max_content_chars, do: text

  defp truncate(text) do
    text
    |> String.slice(0, @max_content_chars)
    |> Kernel.<>("\n\n[truncated]")
  end

  defp content_type(headers) do
    headers
    |> header("content-type")
    |> case do
      nil -> "application/octet-stream"
      value -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp format_error(reason) do
    reason
    |> inspect()
    |> String.slice(0, 500)
  end
end
