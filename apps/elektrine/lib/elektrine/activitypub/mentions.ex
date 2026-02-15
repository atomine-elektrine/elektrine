defmodule Elektrine.ActivityPub.Mentions do
  @moduledoc """
  Handles mention extraction and federation for ActivityPub.
  """

  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher

  @doc """
  Extracts remote mentions from text content.
  Matches @user@domain.com format.
  """
  def extract_mentions(content) when is_binary(content) do
    # Regex for @username@domain.com
    ~r/@([a-zA-Z0-9_]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, username, domain] ->
      %{username: username, domain: domain, handle: "#{username}@#{domain}"}
    end)
    |> Enum.uniq_by(& &1.handle)
  end

  def extract_mentions(nil), do: []
  def extract_mentions(_), do: []

  @doc """
  Resolves mentions to ActivityPub actor URIs.
  Returns {actor_uris, inbox_urls} for including in activities.
  """
  def resolve_mentions(content) do
    mentions = extract_mentions(content)

    mentions
    |> Enum.map(fn mention ->
      case Fetcher.webfinger_lookup(mention.handle) do
        {:ok, actor_uri} ->
          case ActivityPub.get_or_fetch_actor(actor_uri) do
            {:ok, actor} ->
              %{
                uri: actor.uri,
                inbox: actor.inbox_url,
                handle: mention.handle
              }

            {:error, reason} ->
              Logger.warning(
                "Failed to fetch mentioned actor #{mention.handle}: #{inspect(reason)}"
              )

              nil
          end

        {:error, reason} ->
          Logger.warning("WebFinger failed for #{mention.handle}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  @doc """
  Gets inbox URLs for mentioned users.
  """
  def get_mention_inboxes(content) do
    resolved = resolve_mentions(content)
    Enum.map(resolved, & &1.inbox)
  end

  @doc """
  Gets actor URIs for mentioned users (for cc field).
  """
  def get_mention_uris(content) do
    resolved = resolve_mentions(content)
    Enum.map(resolved, & &1.uri)
  end
end
