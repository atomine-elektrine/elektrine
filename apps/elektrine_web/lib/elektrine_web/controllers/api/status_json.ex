defmodule ElektrineWeb.API.StatusJSON do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.Accounts.{UserBlock, UserMute}
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.UserBlock, as: ActivityPubUserBlock
  alias Elektrine.Repo
  alias Elektrine.Social.MessageReaction
  alias Elektrine.Social.SavedItem
  alias ElektrineWeb.API.AccountJSON
  alias ElektrineWeb.Platform.Integrations

  def format_statuses(posts, user_id) do
    context_posts = status_context_posts(posts)
    post_ids = Enum.map(context_posts, & &1.id)

    liked_ids = MapSet.new(Integrations.social_user_liked_ids(user_id, post_ids))
    boosted_ids = MapSet.new(Integrations.social_user_boosted_ids(user_id, post_ids))
    saved_ids = MapSet.new(Integrations.social_user_saved_ids(user_id, post_ids))
    bookmark_folders = bookmark_folders_by_post_id(post_ids, user_id)
    muted_ids = muted_status_ids(context_posts, user_id)
    reaction_groups = reaction_groups_by_post_id(post_ids, user_id)
    account_counts = AccountJSON.status_account_count_context(context_posts)

    Enum.map(posts, fn post ->
      format_status(
        post,
        liked_ids,
        boosted_ids,
        saved_ids,
        bookmark_folders,
        muted_ids,
        user_id,
        Map.get(reaction_groups, post.id, []),
        account_counts
      )
    end)
  end

  def format_status(post, liked_ids, boosted_ids, saved_ids, user_id) do
    format_status(
      post,
      liked_ids,
      boosted_ids,
      saved_ids,
      %{},
      MapSet.new(),
      user_id,
      [],
      AccountJSON.status_account_count_context([post])
    )
  end

  def format_status(post, liked_ids, boosted_ids, saved_ids, user_id, emoji_reactions) do
    format_status(
      post,
      liked_ids,
      boosted_ids,
      saved_ids,
      %{},
      MapSet.new(),
      user_id,
      emoji_reactions,
      AccountJSON.status_account_count_context([post])
    )
  end

  def format_status(
        post,
        liked_ids,
        boosted_ids,
        saved_ids,
        bookmark_folders,
        muted_ids,
        user_id,
        emoji_reactions,
        account_counts
      ) do
    metadata = status_metadata(post)
    relationship_id = relationship_status_id(post)
    thread_muted? = MapSet.member?(muted_ids, {:thread, post.id})
    muted? = thread_muted? or MapSet.member?(muted_ids, {:author, post.id})

    %{
      id: to_string(post.id),
      uri: status_uri(post),
      url: status_url(post),
      content: post.content || "",
      text: nil,
      card: status_card(metadata),
      visibility: post.visibility,
      spoiler_text: post.content_warning || "",
      sensitive: post.sensitive || false,
      created_at: post.inserted_at,
      edited_at: post.edited_at,
      account: AccountJSON.format_status_account(post, user_id, account_counts),
      favourited: MapSet.member?(liked_ids, relationship_id),
      reblogged: MapSet.member?(boosted_ids, relationship_id),
      bookmarked: MapSet.member?(saved_ids, relationship_id),
      muted: muted?,
      pinned: post.is_pinned || false,
      favourites_count: post.like_count || 0,
      reblogs_count: post.share_count || 0,
      replies_count: post.reply_count || 0,
      quotes_count: post.quote_count || 0,
      in_reply_to_id: maybe_to_string(post.reply_to_id),
      in_reply_to_account_id: reply_to_account_id(post),
      in_quote_to_id: maybe_to_string(Map.get(post, :quoted_message_id)),
      reblog:
        reblog_status(
          post,
          liked_ids,
          boosted_ids,
          saved_ids,
          bookmark_folders,
          muted_ids,
          user_id,
          account_counts
        ),
      poll: ElektrineWeb.API.PollJSON.format_poll(Map.get(post, :poll), user_id),
      media_attachments: media_attachments(post),
      mentions: status_mentions(post),
      tags: status_tags(post),
      emojis: status_emojis(metadata),
      application: status_application(metadata),
      language: status_language(metadata),
      emoji_reactions: emoji_reactions,
      pleroma: %{
        emoji_reactions: emoji_reactions,
        bookmark_folder: Map.get(bookmark_folders, relationship_id),
        local: local_status?(post),
        conversation_id: maybe_to_string(post.conversation_id),
        context: status_context(post),
        quote_id: maybe_to_string(Map.get(post, :quoted_message_id)),
        quote_url: quoted_status_url(post),
        quote_visible: not is_nil(loaded_assoc(Map.get(post, :quoted_message))),
        content: %{"text/plain" => post.content || ""},
        spoiler_text: %{"text/plain" => post.content_warning || ""},
        expires_at: status_expires_at(metadata),
        thread_muted: thread_muted?,
        visible_reactions: true,
        pinned_at: post.pinned_at,
        quotes_count: post.quote_count || 0
      }
    }
  end

  defp reblog_status(
         %{shared_message_id: shared_message_id} = post,
         liked_ids,
         boosted_ids,
         saved_ids,
         bookmark_folders,
         muted_ids,
         user_id,
         account_counts
       )
       when is_integer(shared_message_id) do
    case loaded_assoc(Map.get(post, :shared_message)) do
      %{id: ^shared_message_id} = shared ->
        format_status(
          %{shared | shared_message_id: nil},
          liked_ids,
          boosted_ids,
          saved_ids,
          bookmark_folders,
          muted_ids,
          user_id,
          [],
          account_counts
        )

      _ ->
        nil
    end
  end

  defp reblog_status(
         _post,
         _liked_ids,
         _boosted_ids,
         _saved_ids,
         _bookmark_folders,
         _muted_ids,
         _user_id,
         _account_counts
       ),
       do: nil

  defp relationship_status_id(%{shared_message_id: shared_message_id})
       when is_integer(shared_message_id),
       do: shared_message_id

  defp relationship_status_id(%{id: id}), do: id

  defp status_context_posts(posts) do
    posts
    |> Enum.flat_map(fn post ->
      case loaded_assoc(Map.get(post, :shared_message)) do
        nil -> [post]
        shared -> [post, shared]
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp status_uri(post) do
    present_string(Map.get(post, :activitypub_id)) ||
      present_string(Map.get(post, :activitypub_url)) ||
      status_url(post)
  end

  defp status_url(post) do
    present_string(Map.get(post, :activitypub_url)) ||
      present_string(Map.get(post, :activitypub_id)) ||
      absolute_url(Elektrine.Paths.post_path(post))
  end

  defp quoted_status_url(post) do
    post
    |> Map.get(:quoted_message)
    |> loaded_assoc()
    |> case do
      nil -> nil
      quoted -> status_url(quoted)
    end
  end

  defp status_context(%{media_metadata: metadata}) when is_map(metadata) do
    present_string(metadata["context"]) || present_string(metadata[:context])
  end

  defp status_context(_post), do: nil

  defp local_status?(post) do
    Map.get(post, :federated) != true and is_nil(Map.get(post, :remote_actor_id))
  end

  defp absolute_url(nil), do: nil
  defp absolute_url("http" <> _ = url), do: url
  defp absolute_url("/" <> _ = path), do: ElektrineWeb.Endpoint.url() <> path
  defp absolute_url(url), do: url

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp loaded_assoc(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_assoc(value), do: value

  defp bookmark_folders_by_post_id([], _user_id), do: %{}
  defp bookmark_folders_by_post_id(_post_ids, user_id) when not is_integer(user_id), do: %{}

  defp bookmark_folders_by_post_id(post_ids, user_id) do
    SavedItem
    |> where([saved], saved.user_id == ^user_id and saved.message_id in ^post_ids)
    |> join(:left, [saved], folder in assoc(saved, :bookmark_folder))
    |> select([saved, folder], %{
      message_id: saved.message_id,
      folder_id: folder.id
    })
    |> Repo.all()
    |> Map.new(fn
      %{message_id: message_id, folder_id: nil} ->
        {message_id, nil}

      %{message_id: message_id, folder_id: folder_id} ->
        {message_id, folder_id}
    end)
  end

  defp muted_status_ids(_posts, user_id) when not is_integer(user_id), do: MapSet.new()

  defp muted_status_ids(posts, user_id) do
    key_by_id =
      posts
      |> Enum.map(&{&1.id, thread_key(&1)})
      |> Enum.reject(fn {_id, key} -> is_nil(key) or key == "" end)
      |> Map.new()

    keys = key_by_id |> Map.values() |> Enum.uniq()

    muted_keys =
      case keys do
        [] ->
          MapSet.new()

        _ ->
          "social_thread_mutes"
          |> where(
            [mute],
            field(mute, :user_id) == ^user_id and field(mute, :thread_key) in ^keys
          )
          |> select([mute], field(mute, :thread_key))
          |> Repo.all()
          |> MapSet.new()
      end

    key_by_id
    |> Enum.filter(fn {_id, key} -> MapSet.member?(muted_keys, key) end)
    |> Enum.map(fn {id, _key} -> {:thread, id} end)
    |> Kernel.++(muted_author_status_keys(posts, user_id))
    |> MapSet.new()
  end

  defp muted_author_status_keys(posts, user_id) do
    posts_by_local_author =
      posts
      |> Enum.filter(&is_integer(Map.get(&1, :sender_id)))
      |> Enum.group_by(& &1.sender_id)

    local_author_ids = Map.keys(posts_by_local_author)

    muted_local_author_ids =
      case local_author_ids do
        [] ->
          MapSet.new()

        _ ->
          UserMute
          |> where(
            [mute],
            mute.muter_id == ^user_id and mute.muted_id in ^local_author_ids and
              (is_nil(mute.expires_at) or mute.expires_at > ^DateTime.utc_now())
          )
          |> select([mute], mute.muted_id)
          |> Repo.all()
          |> MapSet.new()
      end

    local_status_keys =
      posts_by_local_author
      |> Enum.filter(fn {author_id, _posts} ->
        MapSet.member?(muted_local_author_ids, author_id)
      end)
      |> Enum.flat_map(fn {_author_id, posts} -> Enum.map(posts, &{:author, &1.id}) end)

    remote_status_keys = muted_remote_author_status_keys(posts, user_id)

    local_status_keys ++ remote_status_keys
  end

  defp muted_remote_author_status_keys(posts, user_id) do
    remote_actor_ids =
      posts
      |> Enum.map(&Map.get(&1, :remote_actor_id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    muted_remote_actor_ids =
      case remote_actor_ids do
        [] ->
          MapSet.new()

        _ ->
          Actor
          |> join(:inner, [actor], block in ActivityPubUserBlock,
            on: block.blocked_uri == actor.uri
          )
          |> where(
            [actor, block],
            actor.id in ^remote_actor_ids and block.user_id == ^user_id and
              block.block_type == "mute"
          )
          |> select([actor, _block], actor.id)
          |> Repo.all()
          |> MapSet.new()
      end

    posts
    |> Enum.filter(fn post -> MapSet.member?(muted_remote_actor_ids, post.remote_actor_id) end)
    |> Enum.map(&{:author, &1.id})
  end

  defp thread_key(message) do
    metadata = Map.get(message, :media_metadata) || %{}

    cond do
      is_binary(metadata["context"]) and metadata["context"] != "" ->
        "ap:" <> metadata["context"]

      is_binary(metadata[:context]) and metadata[:context] != "" ->
        "ap:" <> metadata[:context]

      is_binary(metadata["inReplyTo"]) and metadata["inReplyTo"] != "" ->
        "ap:" <> metadata["inReplyTo"]

      is_binary(metadata[:inReplyTo]) and metadata[:inReplyTo] != "" ->
        "ap:" <> metadata[:inReplyTo]

      is_integer(Map.get(message, :reply_to_id)) ->
        "message:" <> Integer.to_string(message.reply_to_id)

      is_integer(Map.get(message, :id)) ->
        "message:" <> Integer.to_string(message.id)

      true ->
        nil
    end
  end

  defp reaction_groups_by_post_id([], _user_id), do: %{}

  defp reaction_groups_by_post_id(post_ids, user_id) do
    hidden_user_ids = hidden_reactor_ids(user_id)

    MessageReaction
    |> where([reaction], reaction.message_id in ^post_ids)
    |> order_by([reaction],
      asc: reaction.message_id,
      asc: reaction.emoji,
      asc: reaction.inserted_at,
      asc: reaction.id
    )
    |> select([reaction], %{
      message_id: reaction.message_id,
      emoji: reaction.emoji,
      emoji_url: reaction.emoji_url,
      user_id: reaction.user_id,
      remote_actor_id: reaction.remote_actor_id
    })
    |> Repo.all()
    |> Enum.reject(fn
      %{user_id: reactor_id} when is_integer(reactor_id) and reactor_id != user_id ->
        MapSet.member?(hidden_user_ids, reactor_id)

      _reaction ->
        false
    end)
    |> Enum.group_by(& &1.message_id)
    |> Map.new(fn {message_id, reactions} ->
      {message_id, format_emoji_reactions(reactions, user_id)}
    end)
  end

  defp format_emoji_reactions(reactions, user_id) do
    reactions
    |> Enum.group_by(fn reaction -> {reaction.emoji, reaction.emoji_url} end)
    |> Enum.map(fn {{emoji, emoji_url}, grouped_reactions} ->
      %{
        name: emoji,
        count: length(grouped_reactions),
        me: Enum.any?(grouped_reactions, &(&1.user_id == user_id)),
        url: emoji_url
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp hidden_reactor_ids(user_id) when is_integer(user_id) do
    muted_ids =
      Repo.all(
        from mute in UserMute,
          where: mute.muter_id == ^user_id,
          select: mute.muted_id
      )

    blocked_ids =
      Repo.all(
        from block in UserBlock,
          where: block.blocker_id == ^user_id or block.blocked_id == ^user_id,
          select:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE ? END",
              block.blocker_id,
              ^user_id,
              block.blocked_id,
              block.blocker_id
            )
      )

    muted_ids
    |> Kernel.++(blocked_ids)
    |> MapSet.new()
  end

  defp hidden_reactor_ids(_user_id), do: MapSet.new()

  defp media_attachments(%{media_metadata: metadata, media_urls: media_urls})
       when is_map(metadata) do
    attachments_by_url =
      metadata
      |> Map.get("attachments", [])
      |> case do
        attachments when is_list(attachments) ->
          Map.new(attachments, fn attachment ->
            url = attachment["url"] || attachment["id"]
            {url, attachment}
          end)

        _ ->
          %{}
      end

    media_urls
    |> List.wrap()
    |> Enum.map(fn url ->
      attachment = Map.get(attachments_by_url, url, %{})

      %{
        id: to_string(attachment["id"] || url),
        type: media_type(attachment, url),
        url: media_url(url),
        preview_url: media_url(attachment["preview_url"] || url),
        description: attachment["description"] || attachment["alt_text"] || attachment["name"]
      }
    end)
  end

  defp media_attachments(_post), do: []

  defp media_type(%{"mime_type" => "image/" <> _}, _url), do: "image"
  defp media_type(%{"mime_type" => "video/" <> _}, _url), do: "video"
  defp media_type(%{"mime_type" => "audio/" <> _}, _url), do: "audio"

  defp media_type(_attachment, url) when is_binary(url) do
    case String.downcase(Path.extname(url)) do
      ext when ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif"] -> "image"
      ext when ext in [".mp4", ".mov", ".m4v", ".webm"] -> "video"
      ext when ext in [".mp3", ".m4a", ".ogg", ".wav", ".flac"] -> "audio"
      _ -> "unknown"
    end
  end

  defp media_type(_attachment, _url), do: "unknown"

  defp media_url(nil), do: nil

  defp media_url(url) when is_binary(url) do
    case Elektrine.Uploads.attachment_url(url) do
      {:error, _reason} -> url
      absolute_url -> absolute_url
    end
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp status_metadata(%{media_metadata: metadata}) when is_map(metadata), do: metadata
  defp status_metadata(_post), do: %{}

  defp status_card(metadata) do
    case metadata_value(metadata, "card") do
      card when is_map(card) -> card
      _ -> nil
    end
  end

  defp status_application(metadata) do
    case metadata_value(metadata, "application") || metadata_value(metadata, "generator") do
      %{"name" => name} = app when is_binary(name) ->
        %{
          name: name,
          website: present_string(app["website"] || app["url"])
        }

      %{name: name} = app when is_binary(name) ->
        %{
          name: name,
          website: present_string(app[:website] || app[:url])
        }

      _ ->
        nil
    end
  end

  defp status_language(metadata) do
    case present_string(metadata_value(metadata, "language")) do
      nil -> nil
      "und" -> nil
      language -> language
    end
  end

  defp status_expires_at(metadata), do: metadata_value(metadata, "expires_at")

  defp status_emojis(metadata) do
    case metadata_value(metadata, "emoji") || metadata_value(metadata, "emojis") do
      emojis when is_list(emojis) -> emojis
      emojis when is_map(emojis) -> format_custom_emoji_map(emojis)
      _ -> []
    end
  end

  defp format_custom_emoji_map(emojis) do
    emojis
    |> Enum.map(fn {shortcode, url} ->
      %{
        shortcode: to_string(shortcode),
        url: url,
        static_url: url,
        visible_in_picker: false
      }
    end)
    |> Enum.sort_by(& &1.shortcode)
  end

  defp status_tags(%{extracted_hashtags: hashtags}) when is_list(hashtags) do
    hashtags
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn hashtag ->
      name =
        hashtag
        |> to_string()
        |> String.trim_leading("#")

      %{
        name: name,
        url: absolute_url("/tags/#{URI.encode(name)}")
      }
    end)
  end

  defp status_tags(_post), do: []

  defp status_mentions(_post), do: []

  defp reply_to_account_id(post) do
    post
    |> Map.get(:reply_to)
    |> loaded_assoc()
    |> case do
      %{sender_id: sender_id} when is_integer(sender_id) ->
        to_string(sender_id)

      %{remote_actor_id: remote_actor_id} when is_integer(remote_actor_id) ->
        "remote:#{remote_actor_id}"

      _ ->
        nil
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end

  defp metadata_value(_metadata, _key), do: nil
end
