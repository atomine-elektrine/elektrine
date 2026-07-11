defmodule Elektrine.WebIndex.Extractor do
  @moduledoc "Extracts indexable text, metadata, and same-site links from HTML."

  @max_content_chars 120_000
  @max_links 60
  @ignored_extensions ~w(.7z .avi .css .csv .doc .docx .exe .gif .gz .ico .jpeg .jpg .js .json .m4a .mkv .mov .mp3 .mp4 .pdf .png .ppt .pptx .rar .rss .svg .tar .tgz .webm .webp .xml .zip)

  def extract(html, fetched_url) when is_binary(html) and is_binary(fetched_url) do
    with {:ok, tree} <- Floki.parse_document(html) do
      cleaned =
        Floki.filter_out(tree, "script,style,noscript,svg,canvas,nav,footer,header,aside,form")

      title = cleaned |> text("title") |> truncate(500)
      description = cleaned |> attribute("meta[name='description']", "content") |> truncate(1_000)
      canonical_url = canonical_url(cleaned, fetched_url)

      content =
        cleaned |> Floki.text(sep: " ") |> clean_text() |> String.slice(0, @max_content_chars)

      {:ok,
       %{
         title: title,
         description: description,
         canonical_url: canonical_url,
         content: content,
         content_hash: :crypto.hash(:sha256, content),
         language: attribute(cleaned, "html", "lang") |> normalize_language(),
         noindex?: noindex?(tree),
         links: links(tree, fetched_url)
       }}
    end
  end

  def extract(_html, _fetched_url), do: {:error, :invalid_html}

  defp links(tree, fetched_url) do
    fetched_host = URI.parse(fetched_url).host

    tree
    |> Floki.find("a[href]")
    |> Floki.attribute("href")
    |> Enum.flat_map(&absolute_url(fetched_url, &1))
    |> Enum.filter(&(URI.parse(&1).host == fetched_host))
    |> Enum.reject(&ignored_url?/1)
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  defp absolute_url(base_url, href) do
    href = String.trim(href)

    if href == "" or String.starts_with?(href, ["#", "mailto:", "tel:", "javascript:", "data:"]) do
      []
    else
      url =
        base_url |> URI.parse() |> URI.merge(href) |> Map.put(:fragment, nil) |> URI.to_string()

      case Elektrine.WebIndex.normalize_url(url) do
        {:ok, normalized, _host} -> [normalized]
        {:error, _reason} -> []
      end
    end
  rescue
    _error -> []
  end

  defp canonical_url(tree, fetched_url) do
    case attribute(tree, "link[rel='canonical']", "href") do
      nil ->
        fetched_url

      href ->
        candidate = absolute_url(fetched_url, href) |> List.first()

        if candidate && URI.parse(candidate).host == URI.parse(fetched_url).host,
          do: candidate,
          else: fetched_url
    end
  end

  defp noindex?(tree) do
    tree
    |> Floki.find("meta[name='robots'],meta[name='googlebot']")
    |> Floki.attribute("content")
    |> Enum.any?(fn value ->
      value
      |> String.downcase()
      |> String.split([",", " "], trim: true)
      |> Enum.member?("noindex")
    end)
  end

  defp ignored_url?(url) do
    path = url |> URI.parse() |> Map.get(:path) |> to_string() |> String.downcase()
    Enum.any?(@ignored_extensions, &String.ends_with?(path, &1))
  end

  defp text(tree, selector) do
    tree |> Floki.find(selector) |> Floki.text(sep: " ") |> clean_text() |> present()
  end

  defp attribute(tree, selector, name) do
    tree |> Floki.find(selector) |> Floki.attribute(name) |> List.first() |> present()
  end

  defp clean_text(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp present(nil), do: nil
  defp present(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp normalize_language(nil), do: nil

  defp normalize_language(value),
    do: value |> String.downcase() |> String.split("-", parts: 2) |> hd()

  defp truncate(nil, _limit), do: nil
  defp truncate(value, limit), do: String.slice(value, 0, limit)
end
