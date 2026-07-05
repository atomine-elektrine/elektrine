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

  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator
  alias Kairo.Source

  @user_agent "Elektrine/1.0 (Kairo Ingest)"
  @max_body_bytes 5 * 1024 * 1024
  @max_redirects 3
  @max_content_chars 200_000
  @html_types ~w(text/html application/xhtml+xml)
  @text_types ~w(text/plain text/markdown)

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
      (is_nil(source.content) or String.trim(source.content) == "")
  end

  defp hydrate(source) do
    {:ok, source} = transition(source, %{"status" => "processing"})

    case fetch(source.url) do
      {:ok, page} ->
        {:ok, _source} =
          transition(source, %{
            "status" => "compiled",
            "title" => source.title || page.title,
            "content" => page.content,
            "content_format" => page.content_format,
            "metadata" =>
              Map.merge(source.metadata || %{}, %{
                "fetched_url" => page.final_url,
                "fetched_content_type" => page.content_type
              }),
            "error_message" => nil,
            "processed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
          })

        :ok

      {:error, reason, retry} ->
        {:ok, _source} =
          transition(source, %{
            "status" => "failed",
            "error_message" => format_error(reason)
          })

        case retry do
          :retry -> {:error, reason}
          :discard -> {:discard, reason}
        end
    end
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
    case Application.get_env(:elektrine, :kairo_url_fetch_fun) do
      fun when is_function(fun, 1) -> fun.(url)
      nil -> fetch_remote(url, @max_redirects)
    end
  end

  defp fetch_remote(url, redirects_left) do
    with {:ok, safe_url} <- validate_url(url) do
      request = Finch.build(:get, safe_url, [{"user-agent", @user_agent}])

      case SafeFetch.request(request, Elektrine.Finch,
             receive_timeout: 30_000,
             max_body_bytes: @max_body_bytes
           ) do
        {:ok, %{status: 200, body: body, headers: headers}} ->
          build_page(safe_url, body, content_type(headers))

        {:ok, %{status: status, headers: headers}} when status in 301..308 ->
          follow_redirect(headers, safe_url, redirects_left)

        {:ok, %{status: status}} when status in 400..499 ->
          {:error, {:http_error, status}, :discard}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}, :retry}

        {:error, reason} ->
          {:error, reason, :retry}
      end
    end
  end

  defp follow_redirect(_headers, _current_url, 0), do: {:error, :too_many_redirects, :discard}

  defp follow_redirect(headers, current_url, redirects_left) do
    case header(headers, "location") do
      nil ->
        {:error, :redirect_without_location, :discard}

      location ->
        current_url |> URI.merge(location) |> URI.to_string() |> fetch_remote(redirects_left - 1)
    end
  end

  defp validate_url(url) do
    case URLValidator.validate(url) do
      :ok -> {:ok, url}
      {:error, reason} -> {:error, {:unsafe_url, reason}, :discard}
    end
  end

  defp build_page(final_url, body, content_type) do
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
