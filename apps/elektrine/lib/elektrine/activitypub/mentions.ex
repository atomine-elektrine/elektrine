defmodule Elektrine.ActivityPub.Mentions do
  @moduledoc """
  Handles mention extraction and federation for ActivityPub.
  """

  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.Domains

  @remote_mention_regex ~r/(^|[^A-Za-z0-9_@\/])@([a-zA-Z0-9_]+)@((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63})(?![A-Za-z0-9.-])/u
  @local_mention_regex ~r/(^|[^A-Za-z0-9_@\/])@([a-zA-Z0-9_]+)(?![A-Za-z0-9_@.])/u
  @non_fediverse_mention_regex ~r/(^|[^A-Za-z0-9_@\/])@((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63})(?![A-Za-z0-9._-])/u
  @non_fediverse_handle_regex ~r/(^|[^A-Za-z0-9._%+-@\/])([A-Za-z0-9][A-Za-z0-9._-]{0,62}@(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63})(?![A-Za-z0-9._-])/u

  @doc """
  Extracts remote mentions from text content.
  Matches @user@domain.com format.
  """
  def extract_mentions(content) when is_binary(content) do
    Regex.scan(@remote_mention_regex, content)
    |> Enum.map(fn [_full, _prefix, username, domain] ->
      %{username: username, domain: domain, handle: "#{username}@#{domain}"}
    end)
    |> Enum.uniq_by(& &1.handle)
  end

  def extract_mentions(nil), do: []
  def extract_mentions(_), do: []

  @doc """
  Extracts local mentions from text content.
  Supports both @user and @user@local-domain while ignoring non-federated
  handles like @x.com.
  """
  def extract_local_mentions(content) when is_binary(content) do
    short_mentions =
      Regex.scan(@local_mention_regex, content)
      |> Enum.map(fn [_full, _prefix, username] ->
        %{username: username, handle: username}
      end)

    local_federated_mentions =
      extract_mentions(content)
      |> Enum.filter(fn mention -> Domains.local_activitypub_domain?(mention.domain) end)
      |> Enum.map(fn mention -> %{username: mention.username, handle: mention.handle} end)

    (short_mentions ++ local_federated_mentions)
    |> Enum.uniq_by(&String.downcase(&1.username))
  end

  def extract_local_mentions(nil), do: []
  def extract_local_mentions(_), do: []

  @doc """
  Extracts non-federated domain-style handles like @x.com.
  """
  def extract_non_fediverse_mentions(content) when is_binary(content) do
    domain_only_mentions =
      Regex.scan(@non_fediverse_mention_regex, content)
      |> Enum.map(fn [_full, _prefix, handle] -> %{handle: handle} end)

    bare_handle_mentions =
      Regex.scan(@non_fediverse_handle_regex, content)
      |> Enum.map(fn [_full, _prefix, handle] -> %{handle: handle} end)

    (domain_only_mentions ++ bare_handle_mentions)
    |> Enum.uniq_by(&String.downcase(&1.handle))
  end

  def extract_non_fediverse_mentions(nil), do: []
  def extract_non_fediverse_mentions(_), do: []

  @doc """
  Counts mention-like tokens across local, federated, and non-federated handles.
  """
  def count_mentions(content) when is_binary(content) do
    length(Regex.scan(@local_mention_regex, content)) +
      length(Regex.scan(@remote_mention_regex, content)) +
      length(Regex.scan(@non_fediverse_mention_regex, content)) +
      length(Regex.scan(@non_fediverse_handle_regex, content))
  end

  def count_mentions(_), do: 0

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
