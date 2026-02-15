defmodule Elektrine.RSS.FetchFeedWorker do
  @moduledoc """
  Oban worker that fetches and parses an RSS/Atom feed, storing new items.
  """
  use Oban.Worker, queue: :rss, max_attempts: 3

  require Logger

  alias Elektrine.RSS
  alias Elektrine.RSS.Feed

  @user_agent "Elektrine/1.0 (RSS Reader; +https://z.org)"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed_id" => feed_id}}) do
    case RSS.get_feed(feed_id) do
      nil ->
        Logger.warning("Feed not found: #{feed_id}")
        :ok

      feed ->
        fetch_and_process(feed)
    end
  end

  defp fetch_and_process(%Feed{} = feed) do
    headers = build_headers(feed)

    case Finch.build(:get, feed.url, headers)
         |> Finch.request(Elektrine.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body, headers: resp_headers}} ->
        process_feed(feed, body, resp_headers)

      {:ok, %Finch.Response{status: 304}} ->
        # Not modified, just update last_fetched_at
        RSS.update_feed(feed, %{last_fetched_at: DateTime.utc_now()})
        :ok

      {:ok, %Finch.Response{status: status, headers: redirect_headers}} when status in 301..308 ->
        # Handle redirects
        case get_header(redirect_headers, "location") do
          nil ->
            RSS.update_feed(feed, %{
              last_error: "Redirect without location header",
              last_fetched_at: DateTime.utc_now()
            })

            {:error, :redirect_without_location}

          new_url ->
            Logger.info("Feed #{feed.id} redirected to #{new_url}")
            RSS.update_feed(feed, %{url: new_url})
            # Retry with new URL
            {:snooze, 5}
        end

      {:ok, %Finch.Response{status: status}} ->
        RSS.update_feed(feed, %{
          last_error: "HTTP #{status}",
          last_fetched_at: DateTime.utc_now()
        })

        if status in 400..499 do
          :ok
        else
          {:error, {:http_error, status}}
        end

      {:error, reason} ->
        RSS.update_feed(feed, %{
          last_error: inspect(reason),
          last_fetched_at: DateTime.utc_now()
        })

        {:error, reason}
    end
  end

  defp build_headers(%Feed{} = feed) do
    headers = [
      {"user-agent", @user_agent},
      {"accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"}
    ]

    headers =
      if feed.etag do
        [{"if-none-match", feed.etag} | headers]
      else
        headers
      end

    headers =
      if feed.last_modified do
        [{"if-modified-since", feed.last_modified} | headers]
      else
        headers
      end

    headers
  end

  defp process_feed(feed, body, resp_headers) do
    case Elektrine.RSS.Parser.parse(body) do
      {:ok, parsed_feed} ->
        # Update feed metadata
        feed_attrs = %{
          title: parsed_feed.title || feed.title,
          description: parsed_feed.subtitle || feed.description,
          site_url: parsed_feed.link || feed.site_url,
          image_url: parsed_feed.image_url || feed.image_url,
          last_fetched_at: DateTime.utc_now(),
          last_error: nil,
          etag: get_header(resp_headers, "etag"),
          last_modified: get_header(resp_headers, "last-modified"),
          status: "active"
        }

        RSS.update_feed(feed, feed_attrs)

        # Store items
        Enum.each(parsed_feed.entries, fn entry ->
          item_attrs = %{
            guid: entry.guid,
            title: entry.title,
            content: entry.content,
            summary: entry.summary,
            url: entry.link,
            author: entry.author,
            published_at: entry.published_at,
            image_url: detect_image(entry),
            enclosure_url: entry.enclosure_url,
            enclosure_type: entry.enclosure_type,
            categories: entry.categories || []
          }

          RSS.upsert_item(feed.id, item_attrs)
        end)

        :ok

      {:error, reason} ->
        RSS.update_feed(feed, %{
          last_error: "Parse error: #{inspect(reason)}",
          last_fetched_at: DateTime.utc_now()
        })

        {:error, {:parse_error, reason}}
    end
  end

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # Detect image from enclosure if it's an image type
  defp detect_image(%{enclosure_type: type, enclosure_url: url})
       when is_binary(url) and is_binary(type) do
    if String.starts_with?(type, "image/"), do: url, else: nil
  end

  defp detect_image(_), do: nil
end
