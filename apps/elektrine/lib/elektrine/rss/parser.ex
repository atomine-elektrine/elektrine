defmodule Elektrine.RSS.Parser do
  @moduledoc "Simple RSS/Atom feed parser using SweetXml.\nHandles RSS 2.0, RSS 1.0, and Atom feeds.\n"
  import SweetXml

  @doc "Parses an RSS or Atom feed from XML content.\nReturns {:ok, feed_map} or {:error, reason}.\n"
  def parse(xml_content) when is_binary(xml_content) do
    case detect_format(xml_content) do
      :rss2 -> parse_rss2(xml_content)
      :rss1 -> parse_rss1(xml_content)
      :atom -> parse_atom(xml_content)
      :unknown -> {:error, :unknown_format}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  defp detect_format(xml) do
    cond do
      String.contains?(xml, "<feed") &&
          String.contains?(xml, "xmlns=\"http://www.w3.org/2005/Atom\"") ->
        :atom

      String.contains?(xml, "<rss") ->
        :rss2

      String.contains?(xml, "xmlns=\"http://purl.org/rss/1.0/\"") ->
        :rss1

      String.contains?(xml, "<feed") ->
        :atom

      true ->
        :unknown
    end
  end

  defp parse_rss2(xml) do
    feed =
      xml
      |> xpath(~x"//channel"e,
        title: ~x"./title/text()"os,
        description: ~x"./description/text()"os,
        link: ~x"./link/text()"os,
        image_url: ~x"./image/url/text()"os,
        entries: [
          ~x"./item"l,
          guid: ~x"./guid/text()"os,
          title: ~x"./title/text()"os,
          link: ~x"./link/text()"os,
          description: ~x"./description/text()"os,
          content: ~x"./content:encoded/text()"os,
          author: ~x"./author/text()"os |> transform_by(&clean_author/1),
          dc_creator: ~x"./dc:creator/text()"os,
          pub_date: ~x"./pubDate/text()"os,
          enclosure_url: ~x"./enclosure/@url"os,
          enclosure_type: ~x"./enclosure/@type"os,
          categories: ~x"./category/text()"ls
        ]
      )

    entries =
      Enum.map(feed.entries, fn entry ->
        %{
          guid: entry.guid || entry.link,
          title: clean_text(entry.title),
          link: entry.link,
          content: entry.content || entry.description,
          summary: entry.description,
          author: entry.author || entry.dc_creator,
          published_at: parse_date(entry.pub_date),
          enclosure_url: entry.enclosure_url,
          enclosure_type: entry.enclosure_type,
          categories: entry.categories
        }
      end)

    {:ok,
     %{
       title: clean_text(feed.title),
       subtitle: clean_text(feed.description),
       link: feed.link,
       image_url: feed.image_url,
       entries: entries
     }}
  end

  defp parse_rss1(xml) do
    feed =
      xml
      |> xpath(~x"/*[local-name()='RDF']"e,
        title: ~x"./*[local-name()='channel']/*[local-name()='title']/text()"os,
        description: ~x"./*[local-name()='channel']/*[local-name()='description']/text()"os,
        link: ~x"./*[local-name()='channel']/*[local-name()='link']/text()"os,
        entries: [
          ~x"./*[local-name()='item']"l,
          title: ~x"./*[local-name()='title']/text()"os,
          link: ~x"./*[local-name()='link']/text()"os,
          description: ~x"./*[local-name()='description']/text()"os,
          dc_date: ~x"./*[local-name()='date']/text()"os
        ]
      )

    entries =
      Enum.map(feed.entries || [], fn entry ->
        %{
          guid: entry.link,
          title: clean_text(entry.title),
          link: entry.link,
          content: entry.description,
          summary: entry.description,
          author: nil,
          published_at: parse_date(entry.dc_date),
          enclosure_url: nil,
          enclosure_type: nil,
          categories: []
        }
      end)

    {:ok,
     %{
       title: clean_text(feed.title),
       subtitle: clean_text(feed.description),
       link: feed.link,
       image_url: nil,
       entries: entries
     }}
  end

  defp parse_atom(xml) do
    feed =
      xml
      |> xpath(~x"/*[local-name()='feed']"e,
        title: ~x"./*[local-name()='title']/text()"os,
        subtitle: ~x"./*[local-name()='subtitle']/text()"os,
        link: ~x"./*[local-name()='link' and @rel='alternate']/@href"os,
        link_self: ~x"./*[local-name()='link' and @rel='self']/@href"os,
        icon: ~x"./*[local-name()='icon']/text()"os,
        logo: ~x"./*[local-name()='logo']/text()"os,
        entries: [
          ~x"./*[local-name()='entry']"l,
          id: ~x"./*[local-name()='id']/text()"os,
          title: ~x"./*[local-name()='title']/text()"os,
          link: ~x"./*[local-name()='link' and @rel='alternate']/@href"os,
          link_default: ~x"./*[local-name()='link']/@href"os,
          content: ~x"./*[local-name()='content']/text()"os,
          summary: ~x"./*[local-name()='summary']/text()"os,
          author_name: ~x"./*[local-name()='author']/*[local-name()='name']/text()"os,
          updated: ~x"./*[local-name()='updated']/text()"os,
          published: ~x"./*[local-name()='published']/text()"os,
          categories: ~x"./*[local-name()='category']/@term"ls
        ]
      )

    entries =
      Enum.map(feed.entries || [], fn entry ->
        link = entry.link || entry.link_default

        %{
          guid: entry.id || link,
          title: clean_text(entry.title),
          link: link,
          content: entry.content || entry.summary,
          summary: entry.summary,
          author: entry.author_name,
          published_at: parse_date(entry.published || entry.updated),
          enclosure_url: nil,
          enclosure_type: nil,
          categories: entry.categories || []
        }
      end)

    {:ok,
     %{
       title: clean_text(feed.title),
       subtitle: clean_text(feed.subtitle),
       link: feed.link || feed.link_self,
       image_url: feed.logo || feed.icon,
       entries: entries
     }}
  end

  defp clean_text(nil) do
    nil
  end

  defp clean_text(text) when is_binary(text) do
    text |> String.trim() |> HtmlEntities.decode()
  end

  defp clean_author(nil) do
    nil
  end

  defp clean_author(author) when is_binary(author) do
    author = String.trim(author)

    cond do
      String.contains?(author, "(") ->
        case Regex.run(~r/\(([^)]+)\)/, author) do
          [_, name] -> String.trim(name)
          _ -> author
        end

      String.contains?(author, "@") ->
        case String.split(author, "@") do
          [username | _] -> username
          _ -> author
        end

      true ->
        author
    end
  end

  defp parse_date(nil) do
    nil
  end

  defp parse_date("") do
    nil
  end

  defp parse_date(date_string) when is_binary(date_string) do
    date_string = String.trim(date_string)

    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} -> datetime
      _ -> parse_rfc2822(date_string)
    end
  end

  defp parse_rfc2822(date_string) do
    date_string = date_string |> String.replace(~r/\s+/, " ") |> String.trim()

    try do
      date_string =
        if String.match?(date_string, ~r/^\w{3},\s/) do
          String.replace(date_string, ~r/^\w{3},\s*/, "")
        else
          date_string
        end

      case :httpd_util.convert_request_date(String.to_charlist(date_string)) do
        :bad_date ->
          nil

        {{year, month, day}, {hour, min, sec}} ->
          case NaiveDateTime.new(year, month, day, hour, min, sec) do
            {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
            _ -> nil
          end
      end
    rescue
      _ -> nil
    end
  end
end
