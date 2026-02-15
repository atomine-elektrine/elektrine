defmodule Elektrine.Social.LinkPreviewFetcher do
  @moduledoc """
  Fetches link previews by extracting Open Graph and meta tags from URLs.
  """

  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview

  @doc """
  Extracts URLs from text content.
  """
  def extract_urls(content) do
    # Simple URL regex - matches http/https URLs
    url_regex = ~r/https?:\/\/[^\s<>"{}|\\^`\[\]]+/i

    Regex.scan(url_regex, content)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
  end

  @doc """
  Gets or creates a link preview for a URL.
  """
  def get_or_create_preview(url) do
    case Repo.get_by(LinkPreview, url: url) do
      nil ->
        # Create new preview and fetch in background
        create_and_fetch_preview(url)

      %LinkPreview{status: "pending"} = preview ->
        # Already fetching, return existing
        {:ok, preview}

      %LinkPreview{} = preview ->
        # Already exists, return it
        {:ok, preview}
    end
  end

  @doc """
  Fetches link preview metadata using WebFetch tool.
  """
  def fetch_preview_metadata(url) do
    case fetch_url_metadata(url) do
      {:ok, metadata} ->
        %{
          title: metadata["title"],
          description: metadata["description"],
          image_url: metadata["image"],
          site_name: metadata["site_name"],
          favicon_url: metadata["favicon"],
          status: "success",
          fetched_at: DateTime.utc_now()
        }

      {:error, reason} ->
        %{
          status: "failed",
          error_message: to_string(reason),
          fetched_at: DateTime.utc_now()
        }
    end
  end

  @doc """
  Updates a link preview with fetched metadata.
  """
  def update_preview_with_metadata(preview, metadata) do
    preview
    |> LinkPreview.changeset(metadata)
    |> Repo.update()
  end

  @doc """
  Refresh an existing link preview (re-fetch metadata).
  """
  def refresh_preview(url) do
    case Repo.get_by(LinkPreview, url: url) do
      nil ->
        {:error, :not_found}

      preview ->
        metadata = fetch_preview_metadata(url)
        update_preview_with_metadata(preview, metadata)
    end
  end

  @doc """
  Fix HTML entities in existing link previews.
  """
  def fix_html_entities_in_existing_previews() do
    previews = Repo.all(LinkPreview)

    Enum.each(previews, fn preview ->
      updated_attrs = %{
        title: clean_text(preview.title),
        description: clean_text(preview.description),
        site_name: clean_text(preview.site_name)
      }

      preview
      |> LinkPreview.changeset(updated_attrs)
      |> Repo.update()
    end)
  end

  # Private functions

  defp create_and_fetch_preview(url) do
    # Create pending preview
    case %LinkPreview{}
         |> LinkPreview.changeset(%{url: url, status: "pending"})
         |> Repo.insert() do
      {:ok, preview} ->
        # Fetch metadata asynchronously
        Task.start(fn ->
          metadata = fetch_preview_metadata(url)
          update_preview_with_metadata(preview, metadata)
        end)

        {:ok, preview}

      error ->
        error
    end
  end

  defp fetch_url_metadata(url) do
    # SSRF Protection: Validate URL before fetching
    case validate_url_for_ssrf(url) do
      :ok ->
        fetch_url_metadata_internal(url)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_url_metadata_internal(url) do
    # Use a simple approach to extract basic metadata
    try do
      request = Finch.build(:get, url)

      case Finch.request(request, Elektrine.Finch, receive_timeout: 5000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          metadata = parse_html_metadata(body, url)
          {:ok, metadata}

        {:ok, %Finch.Response{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp validate_url_for_ssrf(url) do
    # Use central URL validator for comprehensive SSRF protection
    Elektrine.Security.URLValidator.validate(url)
  end

  defp parse_html_metadata(html, url) do
    # Extract basic Open Graph and meta tags
    title = extract_meta_content(html, "og:title") || extract_title_tag(html)

    description =
      extract_meta_content(html, "og:description") || extract_meta_content(html, "description")

    image = extract_meta_content(html, "og:image")
    site_name = extract_meta_content(html, "og:site_name")

    # Get favicon
    favicon = extract_favicon(html, url)

    %{
      "title" => clean_text(title),
      "description" => clean_text(description),
      "image" => clean_url(image, url),
      "site_name" => clean_text(site_name),
      "favicon" => clean_url(favicon, url)
    }
  end

  defp extract_meta_content(html, property) do
    # Extract content from meta tags
    regex =
      ~r/<meta[^>]*(?:property|name)=["']#{Regex.escape(property)}["'][^>]*content=["']([^"']*)[^>]*>/i

    case Regex.run(regex, html) do
      [_, content] -> content
      _ -> nil
    end
  end

  defp extract_title_tag(html) do
    case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html) do
      [_, title] -> title
      _ -> nil
    end
  end

  defp extract_favicon(html, url) do
    # Look for favicon link
    case Regex.run(
           ~r/<link[^>]*rel=["'](?:icon|shortcut icon)["'][^>]*href=["']([^"']*)[^>]*>/i,
           html
         ) do
      [_, favicon] ->
        favicon

      _ ->
        # Default favicon location
        uri = URI.parse(url)
        "#{uri.scheme}://#{uri.host}/favicon.ico"
    end
  end

  defp clean_text(nil), do: nil

  defp clean_text(text) do
    text
    |> sanitize_utf8()
    |> String.trim()
    |> decode_html_entities()
    # Limit length
    |> String.slice(0, 500)
  end

  # Remove invalid UTF-8 bytes to prevent PostgreSQL encoding errors
  defp sanitize_utf8(text) when is_binary(text) do
    if String.valid?(text) do
      text
    else
      # Replace invalid bytes with replacement character or remove them
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _rest} -> valid
        {:incomplete, valid, _rest} -> valid
        valid when is_binary(valid) -> valid
      end
    end
  end

  defp sanitize_utf8(text), do: text

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp clean_url(nil, _base_url), do: nil

  defp clean_url(url, base_url) do
    absolute_url =
      case URI.parse(url) do
        %{scheme: nil} ->
          # Relative URL, make it absolute
          base_uri = URI.parse(base_url)
          "#{base_uri.scheme}://#{base_uri.host}#{url}"

        _ ->
          url
      end

    # Validate the URL for SSRF before returning
    case Elektrine.Security.URLValidator.validate(absolute_url) do
      :ok -> absolute_url
      {:error, _} -> nil
    end
  end
end
