defmodule Elektrine.ActivityPub.Helpers do
  @moduledoc """
  Shared helper functions for ActivityPub data extraction and formatting.
  """

  import Ecto.Query

  @doc """
  Extracts totalItems from an ActivityPub collection or returns integer directly.

  Handles multiple formats:
  - `%{"totalItems" => count}` - collection object
  - `count` - direct integer
  - `nil` or other - returns 0
  """
  def get_collection_total(collection) when is_map(collection) do
    parse_count(collection["totalItems"])
  end

  def get_collection_total(count) when is_integer(count), do: count
  def get_collection_total(count) when is_binary(count), do: parse_count(count)
  def get_collection_total(_), do: 0

  @doc """
  Extracts interaction count (likes, replies, shares) from an ActivityPub object.

  Handles multiple formats that different platforms use:
  - `object["likes"]["totalItems"]` - collection format
  - `object["likes"]` = integer - direct count
  - `object["likesCount"]` - alternative field name
  """
  def extract_interaction_count(object, type) when is_map(object) do
    # Try multiple formats that different platforms use
    cond do
      # Format 1: Direct collection object with totalItems
      is_map(object[type]) && is_integer(object[type]["totalItems"]) ->
        object[type]["totalItems"]

      # Format 1b: Collection with string totalItems
      is_map(object[type]) && is_binary(object[type]["totalItems"]) ->
        parse_count(object[type]["totalItems"])

      # Format 2: Direct integer count
      is_integer(object[type]) ->
        object[type]

      # Format 2b: Direct numeric string count
      is_binary(object[type]) ->
        parse_count(object[type])

      # Format 3: Alternative field name (e.g., likesCount instead of likes)
      is_integer(object["#{type}Count"]) ->
        object["#{type}Count"]

      is_binary(object["#{type}Count"]) ->
        parse_count(object["#{type}Count"])

      # Format 4: Akkoma/Pleroma style - like_count, announcement_count, repliesCount
      type == "likes" && is_integer(object["like_count"]) ->
        object["like_count"]

      type == "likes" && is_binary(object["like_count"]) ->
        parse_count(object["like_count"])

      type == "shares" && is_integer(object["announcement_count"]) ->
        object["announcement_count"]

      type == "shares" && is_binary(object["announcement_count"]) ->
        parse_count(object["announcement_count"])

      type == "replies" && is_integer(object["repliesCount"]) ->
        object["repliesCount"]

      type == "replies" && is_binary(object["repliesCount"]) ->
        parse_count(object["repliesCount"])

      # Format 4b: Some servers expose comments instead of replies
      type == "replies" && is_integer(object["comments"]) ->
        object["comments"]

      type == "replies" && is_binary(object["comments"]) ->
        parse_count(object["comments"])

      type == "replies" && is_map(object["comments"]) ->
        get_collection_total(object["comments"])

      # Format 5: Mastodon API style field names
      type == "likes" && is_integer(object["favourites_count"]) ->
        object["favourites_count"]

      type == "likes" && is_binary(object["favourites_count"]) ->
        parse_count(object["favourites_count"])

      type == "shares" && is_integer(object["reblogs_count"]) ->
        object["reblogs_count"]

      type == "shares" && is_binary(object["reblogs_count"]) ->
        parse_count(object["reblogs_count"])

      type == "replies" && is_integer(object["replies_count"]) ->
        object["replies_count"]

      type == "replies" && is_binary(object["replies_count"]) ->
        parse_count(object["replies_count"])

      # Default to 0
      true ->
        0
    end
  end

  def extract_interaction_count(_, _), do: 0

  @doc """
  Extracts all engagement counts from an ActivityPub object.

  Returns `{like_count, share_count, reply_count}` tuple.
  """
  def extract_all_counts(object) when is_map(object) do
    {
      extract_interaction_count(object, "likes"),
      extract_interaction_count(object, "shares"),
      extract_interaction_count(object, "replies")
    }
  end

  def extract_all_counts(_), do: {0, 0, 0}

  @doc """
  Extracts follower count from actor metadata.

  Handles various ActivityPub formats:
  - `metadata["followers_count"]` - Mastodon extension
  - `metadata["followersCount"]` - alternative format
  - `metadata["followers"]["totalItems"]` - collection format
  """
  def get_follower_count(metadata) when is_map(metadata) do
    cond do
      is_integer(metadata["followers_count"]) -> metadata["followers_count"]
      is_integer(metadata["followersCount"]) -> metadata["followersCount"]
      is_map(metadata["followers"]) -> metadata["followers"]["totalItems"] || 0
      true -> 0
    end
  end

  def get_follower_count(_), do: 0

  @doc """
  Extracts following count from actor metadata.
  """
  def get_following_count(metadata) when is_map(metadata) do
    cond do
      is_integer(metadata["following_count"]) -> metadata["following_count"]
      is_integer(metadata["followingCount"]) -> metadata["followingCount"]
      is_map(metadata["following"]) -> metadata["following"]["totalItems"] || 0
      true -> 0
    end
  end

  def get_following_count(_), do: 0

  @doc """
  Extracts post/status count from actor metadata.
  """
  def get_status_count(metadata) when is_map(metadata) do
    cond do
      is_integer(metadata["statuses_count"]) -> metadata["statuses_count"]
      is_integer(metadata["statusesCount"]) -> metadata["statusesCount"]
      true -> 0
    end
  end

  def get_status_count(_), do: 0

  @doc """
  Formats an ActivityPub ISO8601 date string to human-readable relative time.
  """
  def format_activitypub_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} ->
        Elektrine.Social.time_ago_in_words(datetime)

      _ ->
        date_string
    end
  end

  def format_activitypub_date(_), do: ""

  @doc """
  Formats a join/published date to human-readable format.
  """
  def format_join_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%B %d, %Y")
  end

  def format_join_date(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_join_date()
  end

  def format_join_date(_), do: "Unknown"

  @doc """
  Parses an ActivityPub published date string to DateTime.
  Returns a truncated DateTime suitable for database storage.
  """
  def parse_published_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} -> DateTime.truncate(datetime, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  def parse_published_date(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Loads interaction state (likes/boosts) for ActivityPub posts for a given user.

  Takes a list of ActivityPub post objects (maps with "id" field) and returns
  a map of activitypub_id => %{liked: bool, boosted: bool, like_delta: 0, boost_delta: 0}
  """
  def load_post_interactions(posts, user_id) when is_list(posts) do
    activitypub_ids = Enum.map(posts, & &1["id"]) |> Enum.filter(& &1)

    if Enum.empty?(activitypub_ids) do
      %{}
    else
      # Find messages that exist locally
      local_messages = Elektrine.Messaging.get_messages_by_activitypub_ids(activitypub_ids)
      message_id_map = Map.new(local_messages, fn msg -> {msg.activitypub_id, msg.id} end)
      message_ids = Enum.map(local_messages, & &1.id)

      # Get liked message IDs
      liked_ids =
        if Enum.empty?(message_ids) do
          MapSet.new()
        else
          from(l in Elektrine.Social.PostLike,
            where: l.user_id == ^user_id and l.message_id in ^message_ids,
            select: l.message_id
          )
          |> Elektrine.Repo.all()
          |> MapSet.new()
        end

      # Get boosted message IDs
      boosted_ids =
        if Enum.empty?(message_ids) do
          MapSet.new()
        else
          from(b in Elektrine.Social.PostBoost,
            where: b.user_id == ^user_id and b.message_id in ^message_ids,
            select: b.message_id
          )
          |> Elektrine.Repo.all()
          |> MapSet.new()
        end

      # Get user's votes (upvote/downvote) - maps message_id to vote_type ("up" or "down")
      user_votes =
        if Enum.empty?(message_ids) do
          %{}
        else
          from(v in Elektrine.Social.MessageVote,
            where: v.user_id == ^user_id and v.message_id in ^message_ids,
            select: {v.message_id, v.vote_type}
          )
          |> Elektrine.Repo.all()
          |> Map.new()
        end

      # Build result map
      Map.new(activitypub_ids, fn activitypub_id ->
        case Map.get(message_id_map, activitypub_id) do
          nil ->
            {activitypub_id,
             %{
               liked: false,
               boosted: false,
               like_delta: 0,
               boost_delta: 0,
               vote: nil,
               vote_delta: 0
             }}

          message_id ->
            {activitypub_id,
             %{
               liked: MapSet.member?(liked_ids, message_id),
               boosted: MapSet.member?(boosted_ids, message_id),
               like_delta: 0,
               boost_delta: 0,
               vote: Map.get(user_votes, message_id),
               vote_delta: 0
             }}
        end
      end)
    end
  end

  def load_post_interactions(_, _), do: %{}

  @doc """
  Extracts username from an ActivityPub actor URI.

  Handles various URI patterns:
  - `/u/username` - Lemmy format
  - `/users/username` - Mastodon format
  - `/@username` - Mastodon alt format
  """
  def extract_username_from_uri(uri) when is_binary(uri) do
    cond do
      String.contains?(uri, "/u/") ->
        uri |> String.split("/u/") |> List.last() |> String.split("/") |> List.first()

      String.contains?(uri, "/users/") ->
        uri |> String.split("/users/") |> List.last() |> String.split("/") |> List.first()

      String.contains?(uri, "/@") ->
        uri |> String.split("/@") |> List.last() |> String.split("/") |> List.first()

      true ->
        uri |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last()
    end
  end

  def extract_username_from_uri(_), do: "unknown"

  @doc """
  Gets reply count for a post, handling different data formats.
  """
  def get_reply_count(post, remote_counts \\ nil) do
    cond do
      # Remote API counts take priority
      remote_counts && remote_counts.comments ->
        remote_counts.comments

      # Local post with reply_count field
      is_struct(post) && Map.has_key?(post, :reply_count) ->
        post.reply_count || 0

      # ActivityPub object with replies collection
      is_map(post) && is_map(post["replies"]) ->
        get_collection_total(post["replies"])

      # ActivityPub object with repliesCount
      is_map(post) && post["repliesCount"] ->
        post["repliesCount"]

      true ->
        0
    end
  end

  @doc """
  Gets or stores a remote post locally so we can interact with it.

  If the post exists locally, returns it. Otherwise fetches from the remote
  server and stores it using the ActivityPub handler.

  Two variants:
  - `get_or_store_remote_post(activitypub_id)` - extracts actor_uri from fetched post
  - `get_or_store_remote_post(activitypub_id, actor_uri)` - uses provided actor_uri
  """
  def get_or_store_remote_post(activitypub_id) do
    case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
      nil ->
        case Elektrine.ActivityPub.Fetcher.fetch_object(activitypub_id) do
          {:ok, post_object} ->
            actor_uri = post_object["actor"] || post_object["attributedTo"]
            Elektrine.ActivityPub.Handler.store_remote_post(post_object, actor_uri)

          {:error, reason} ->
            {:error, reason}
        end

      message ->
        {:ok, message}
    end
  end

  def get_or_store_remote_post(activitypub_id, actor_uri) do
    case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
      nil ->
        case Elektrine.ActivityPub.Fetcher.fetch_object(activitypub_id) do
          {:ok, post_object} ->
            Elektrine.ActivityPub.Handler.store_remote_post(post_object, actor_uri)

          {:error, reason} ->
            {:error, reason}
        end

      message ->
        {:ok, message}
    end
  end

  @doc """
  Fetches fresh data for federated posts (counts and poll data).

  Returns a map of activitypub_id => %{
    likes: int,
    shares: int, 
    replies: int,
    poll: %{options: [...], total_votes: n, closed: bool} | nil
  }

  This fetches data for non-Lemmy federated posts. Lemmy posts use the dedicated
  LemmyApi module which uses their REST API for better performance.
  """
  def fetch_remote_post_data(posts) when is_list(posts) do
    # Filter to federated posts that aren't Lemmy (Lemmy uses its own API)
    federated_posts =
      Enum.filter(posts, fn post ->
        post.federated && post.activitypub_id && !is_lemmy_post?(post)
      end)

    if Enum.empty?(federated_posts) do
      %{}
    else
      tasks =
        federated_posts
        |> Enum.map(fn post ->
          Task.async(fn ->
            case fetch_single_post_data(post.activitypub_id) do
              {:ok, data} -> {post.activitypub_id, data}
              _ -> nil
            end
          end)
        end)

      results = Task.yield_many(tasks, timeout: 3_000)

      Enum.each(results, fn {task, result} ->
        if result == nil, do: Task.shutdown(task, :brutal_kill)
      end)

      results
      |> Enum.flat_map(fn
        {_task, {:ok, {id, data}}} when is_binary(id) and is_map(data) -> [{id, data}]
        _ -> []
      end)
      |> Map.new()
    end
  end

  def fetch_remote_post_data(_), do: %{}

  defp parse_count(value) when is_integer(value), do: max(value, 0)

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  defp parse_count(_), do: 0

  defp fetch_single_post_data(activitypub_id) do
    case Elektrine.ActivityPub.Fetcher.fetch_object(activitypub_id) do
      {:ok, object} ->
        # Extract counts
        likes = extract_interaction_count(object, "likes")
        shares = extract_interaction_count(object, "shares")
        replies = extract_interaction_count(object, "replies")

        # Extract poll data if it's a Question type
        poll_data =
          if object["type"] == "Question" do
            options = object["oneOf"] || object["anyOf"] || []

            poll_options =
              Enum.map(options, fn option ->
                %{
                  name: option["name"],
                  votes: extract_poll_option_votes(option)
                }
              end)

            total_votes = Enum.reduce(poll_options, 0, fn opt, acc -> acc + opt.votes end)
            end_time = object["endTime"] || object["closed"]

            is_closed =
              case end_time do
                nil ->
                  false

                time_str when is_binary(time_str) ->
                  case DateTime.from_iso8601(time_str) do
                    {:ok, dt, _} -> DateTime.compare(DateTime.utc_now(), dt) != :lt
                    _ -> false
                  end

                _ ->
                  false
              end

            %{
              options: poll_options,
              total_votes: total_votes,
              closed: is_closed,
              end_time: end_time
            }
          else
            nil
          end

        {:ok,
         %{
           likes: likes,
           shares: shares,
           replies: replies,
           poll: poll_data
         }}

      error ->
        error
    end
  end

  # Check if a post is from a Lemmy instance (has /post/ in activitypub_id)
  defp is_lemmy_post?(post) do
    case post.activitypub_id do
      id when is_binary(id) -> String.contains?(id, "/post/")
      _ -> false
    end
  end

  defp extract_poll_option_votes(option) do
    case option["replies"] do
      %{"totalItems" => count} when is_integer(count) -> count
      %{"totalItems" => count} when is_binary(count) -> String.to_integer(count)
      %{} = replies -> replies["totalItems"] || 0
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
