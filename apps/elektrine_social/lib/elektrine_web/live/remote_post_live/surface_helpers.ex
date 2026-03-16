defmodule ElektrineWeb.RemotePostLive.SurfaceHelpers do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.ActorPaths
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social

  def reply_dom_id(%{"_local_message_id" => message_id}) when is_integer(message_id),
    do: "message-#{message_id}"

  def reply_dom_id(%{_local_message_id: message_id}) when is_integer(message_id),
    do: "message-#{message_id}"

  def reply_dom_id(_), do: nil

  def thread_reply_reaction_surface(reply, post_reactions)
      when is_map(reply) and is_map(post_reactions) do
    reply_id = normalize_in_reply_to_ref(reply["id"] || reply[:id])
    local_message_id = thread_reply_local_message_id(reply)

    {target_id, value_name, lookup_keys} =
      cond do
        is_integer(local_message_id) and is_binary(reply_id) ->
          {local_message_id, "message_id",
           [Integer.to_string(local_message_id), local_message_id, reply_id]}

        is_integer(local_message_id) ->
          {local_message_id, "message_id",
           [Integer.to_string(local_message_id), local_message_id]}

        is_binary(reply_id) and reply_id != "" ->
          {reply_id, "post_id", [reply_id]}

        true ->
          {nil, "post_id", []}
      end

    %{
      target_id: target_id,
      value_name: value_name,
      reactions: reactions_for_keys(post_reactions, lookup_keys)
    }
  end

  def thread_reply_reaction_surface(_, _),
    do: %{target_id: nil, value_name: "post_id", reactions: []}

  def ancestor_thread_colors(index) when is_integer(index) do
    case rem(index, 5) do
      0 -> %{rail: "bg-info/65", dot: "bg-info", border: "border-info/70"}
      1 -> %{rail: "bg-secondary/65", dot: "bg-secondary", border: "border-secondary/70"}
      2 -> %{rail: "bg-warning/70", dot: "bg-warning", border: "border-warning/70"}
      3 -> %{rail: "bg-success/65", dot: "bg-success", border: "border-success/70"}
      _ -> %{rail: "bg-error/65", dot: "bg-error", border: "border-error/70"}
    end
  end

  def ancestor_role_label(index, total) when is_integer(index) and is_integer(total) do
    cond do
      total <= 1 -> "Parent"
      index == 0 -> "Root"
      index == total - 1 -> "Parent"
      true -> "Ancestor #{index + 1}"
    end
  end

  def ancestor_role_label(_, _), do: "Ancestor"

  def ancestor_role_badge_class("Root"),
    do: "badge-info border-info/50 bg-info/10 text-info-content"

  def ancestor_role_badge_class("Parent"),
    do: "badge-secondary border-secondary/50 bg-secondary/10 text-secondary-content"

  def ancestor_role_badge_class(_),
    do: "badge-ghost border-base-300/70 bg-base-100/80 text-base-content/80"

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

  def build_reply_author_fallback(reply, reply_author_uri) do
    mastodon_payload = map_get_value(reply, "_mastodon") || %{}

    mastodon_account =
      map_get_value(reply, "_mastodon_account") ||
        map_get_value(mastodon_payload, "account") ||
        %{}

    lemmy_data = map_get_value(reply, "_lemmy") || %{}

    lemmy_creator =
      if is_map(map_get_value(lemmy_data, "creator")),
        do: map_get_value(lemmy_data, "creator"),
        else: %{}

    attributed_to_map = if is_map(reply["attributedTo"]), do: reply["attributedTo"], else: %{}

    account_actor_uri =
      normalize_in_reply_to_ref(map_get_value(mastodon_account, "url")) ||
        normalize_in_reply_to_ref(map_get_value(mastodon_account, "uri"))

    attributed_actor_uri =
      normalize_in_reply_to_ref(map_get_value(attributed_to_map, "id")) ||
        normalize_in_reply_to_ref(map_get_value(attributed_to_map, "url"))

    actor_uri = account_actor_uri || attributed_actor_uri || reply_author_uri
    actor_domain = uri_host(actor_uri)

    {acct_username, acct_domain} = parse_acct_parts(map_get_value(mastodon_account, "acct"))

    username =
      map_get_value(mastodon_account, "username") ||
        map_get_value(attributed_to_map, "preferredUsername") ||
        acct_username ||
        extract_username_from_uri(actor_uri || reply_author_uri)

    domain = actor_domain || acct_domain

    display_name =
      map_get_value(mastodon_account, "display_name") ||
        map_get_value(mastodon_account, "displayName") ||
        map_get_value(attributed_to_map, "name") ||
        map_get_value(lemmy_creator, "display_name") ||
        map_get_value(lemmy_creator, "name") ||
        map_get_value(lemmy_data, "creator_display_name") ||
        map_get_value(lemmy_data, "creator_name") ||
        username ||
        "unknown"

    avatar_url =
      normalize_http_url(map_get_value(mastodon_account, "avatar")) ||
        normalize_http_url(map_get_value(mastodon_account, "avatar_static")) ||
        normalize_http_url(map_get_value(lemmy_creator, "avatar")) ||
        normalize_http_url(map_get_value(lemmy_data, "author_avatar")) ||
        normalize_http_url(map_get_value(lemmy_data, "creator_avatar")) ||
        normalize_http_url(map_get_value(reply, "author_avatar")) ||
        normalize_http_url(map_get_value(reply, "avatar_url")) ||
        first_http_url_from_value(map_get_value(reply, "icon")) ||
        first_http_url_from_value(map_get_value(attributed_to_map, "icon"))

    acct_label =
      cond do
        is_binary(username) && username != "" && is_binary(domain) && domain != "" ->
          "@#{username}@#{domain}"

        is_binary(username) && username != "" ->
          "@#{username}"

        true ->
          nil
      end

    %{
      display_name: display_name,
      avatar_url: avatar_url,
      profile_path: actor_profile_path(username, domain),
      acct_label: acct_label
    }
  end

  def ancestor_interaction_target(parent_post, fallback_ref) when is_map(parent_post) do
    post_ref =
      normalize_in_reply_to_ref(
        map_get_value(parent_post, "id") || map_get_value(parent_post, "url") || fallback_ref
      )

    local_message_id = ancestor_local_message_id(parent_post)

    cond do
      is_integer(local_message_id) ->
        key = Integer.to_string(local_message_id)

        %{
          action_value_name: "message_id",
          action_target: local_message_id,
          interaction_key: key,
          reactions_key: key,
          comment_target: post_ref || key
        }

      is_binary(post_ref) ->
        %{
          action_value_name: "post_id",
          action_target: post_ref,
          interaction_key: post_ref,
          reactions_key: post_ref,
          comment_target: post_ref
        }

      true ->
        nil
    end
  end

  def ancestor_interaction_target(_, _), do: nil

  def ancestor_like_count(parent_post, post_state) when is_map(parent_post) do
    base_count =
      if is_integer(map_get_value(parent_post, "_local_like_count")) do
        map_get_value(parent_post, "_local_like_count")
      else
        max(
          get_collection_total_items(map_get_value(parent_post, "likes")),
          get_collection_total_items(map_get_value(parent_post, "likesCount"))
        )
      end

    base_count + Map.get(post_state, :like_delta, 0)
  end

  def ancestor_like_count(_, _), do: 0

  def ancestor_boost_count(parent_post, post_state) when is_map(parent_post) do
    base_count =
      if is_integer(map_get_value(parent_post, "_local_share_count")) do
        map_get_value(parent_post, "_local_share_count")
      else
        max(
          max(
            get_collection_total_items(map_get_value(parent_post, "shares")),
            get_collection_total_items(map_get_value(parent_post, "sharesCount"))
          ),
          get_collection_total_items(map_get_value(parent_post, "announcesCount"))
        )
      end

    base_count + Map.get(post_state, :boost_delta, 0)
  end

  def ancestor_boost_count(_, _), do: 0

  def ancestor_reply_count(parent_post) when is_map(parent_post) do
    if is_integer(map_get_value(parent_post, "_local_reply_count")) do
      map_get_value(parent_post, "_local_reply_count")
    else
      max(
        max(
          get_collection_total_items(map_get_value(parent_post, "repliesCount")),
          get_collection_total_items(map_get_value(parent_post, "replies"))
        ),
        get_collection_total_items(map_get_value(parent_post, "comments"))
      )
    end
  end

  def ancestor_reply_count(_), do: 0

  def ancestor_local_message_id(parent_post) when is_map(parent_post) do
    case map_get_value(parent_post, "_local_message_id") do
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def ancestor_local_message_id(_), do: nil

  def ancestor_local_message_ids(ancestors) when is_list(ancestors) do
    ancestors
    |> Enum.map(fn ancestor ->
      ancestor
      |> Map.get(:post, Map.get(ancestor, "post"))
      |> ancestor_local_message_id()
    end)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  def ancestor_local_message_ids(_), do: []

  def merge_local_ancestor_reactions(post_reactions, ancestors) do
    local_message_ids = ancestor_local_message_ids(ancestors)

    if local_message_ids == [] do
      post_reactions
    else
      reactions =
        from(r in Messaging.MessageReaction,
          where: r.message_id in ^local_message_ids,
          preload: [:user, :remote_actor]
        )
        |> Repo.all()

      grouped_reactions =
        reactions
        |> Enum.group_by(fn reaction -> Integer.to_string(reaction.message_id) end)

      Map.merge(post_reactions, grouped_reactions, fn _key, _existing, incoming ->
        incoming
      end)
    end
  end

  def merge_reply_reactions(post_reactions, replies)
      when is_map(post_reactions) and is_list(replies) do
    local_message_ids =
      replies
      |> Enum.map(&thread_reply_local_message_id/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if local_message_ids == [] do
      post_reactions
    else
      grouped_reactions =
        from(r in Messaging.MessageReaction,
          where: r.message_id in ^local_message_ids,
          preload: [:user, :remote_actor]
        )
        |> Repo.all()
        |> Enum.group_by(fn reaction -> Integer.to_string(reaction.message_id) end)

      Map.merge(post_reactions, grouped_reactions, fn _key, _existing, incoming -> incoming end)
    end
  end

  def merge_reply_reactions(post_reactions, _), do: post_reactions

  def merge_local_ancestor_interactions(post_interactions, ancestors, user_id) do
    ancestor_local_message_ids(ancestors)
    |> Enum.reduce(post_interactions, fn message_id, acc ->
      key = Integer.to_string(message_id)
      existing = Map.get(acc, key, %{})

      Map.put(acc, key, %{
        liked: Social.user_liked_post?(user_id, message_id),
        boosted: Social.user_boosted?(user_id, message_id),
        like_delta: Map.get(existing, :like_delta, 0),
        boost_delta: Map.get(existing, :boost_delta, 0),
        vote: Map.get(existing, :vote, nil),
        vote_delta: Map.get(existing, :vote_delta, 0)
      })
    end)
  end

  def merge_local_ancestor_saves(user_saves, ancestors, user_id) do
    ancestor_local_message_ids(ancestors)
    |> Enum.reduce(user_saves, fn message_id, acc ->
      Map.put(acc, Integer.to_string(message_id), Social.post_saved?(user_id, message_id))
    end)
  end

  # Convert cached messages (local and federated) to ActivityPub-like format for display
  # in the reply tree.
  def convert_cached_messages_to_ap_format(messages) do
    Enum.map(messages, fn msg ->
      base_url = ElektrineWeb.Endpoint.url()

      {actor_uri, local_user, is_local_reply} =
        cond do
          Ecto.assoc_loaded?(msg.sender) && msg.sender ->
            {"#{base_url}/users/#{msg.sender.username}", msg.sender, true}

          Ecto.assoc_loaded?(msg.remote_actor) && msg.remote_actor && msg.remote_actor.uri ->
            {msg.remote_actor.uri, nil, false}

          Ecto.assoc_loaded?(msg.remote_actor) && msg.remote_actor ->
            {"https://#{msg.remote_actor.domain}/users/#{msg.remote_actor.username}", nil, false}

          true ->
            {nil, nil, false}
        end

      %{
        "id" => msg.activitypub_id || "#{base_url}/messages/#{msg.id}",
        "type" => "Note",
        "attributedTo" => actor_uri,
        "content" => msg.content,
        "published" => NaiveDateTime.to_iso8601(msg.inserted_at) <> "Z",
        "inReplyTo" => Map.get(msg, :parent_activitypub_id),
        "likes" => %{"totalItems" => msg.like_count || 0},
        "_local" => is_local_reply,
        "_local_user" => local_user,
        "_local_message_id" => msg.id
      }
    end)
  end

  # Fetch cached replies and merge with remote replies.
  def merge_local_replies(remote_replies, post_id) do
    seed_activitypub_ids =
      [post_id | Enum.map(remote_replies, & &1["id"])]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    cached_messages = collect_cached_replies(seed_activitypub_ids)

    if Enum.empty?(cached_messages) do
      remote_replies
    else
      cached_ap_format = convert_cached_messages_to_ap_format(cached_messages)

      (remote_replies ++ cached_ap_format)
      |> Enum.uniq_by(&reply_identity_key/1)
    end
  end

  def recent_replies_for_preview(replies, root_post_id, limit \\ 3)

  def recent_replies_for_preview(replies, root_post_id, limit)
      when is_list(replies) and is_binary(root_post_id) do
    replies
    |> Enum.filter(fn reply -> is_map(reply) and reply["inReplyTo"] == root_post_id end)
    |> Enum.sort_by(fn reply -> reply["published"] || "" end, :desc)
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  def recent_replies_for_preview(_, _, _), do: []

  def resolve_comment_target_message(comment_id, replies, ancestors)
      when is_binary(comment_id) do
    local_message_id =
      local_message_id_for_reply(replies, comment_id) ||
        local_message_id_for_ancestor(ancestors, comment_id)

    case local_message_id do
      local_message_id when is_integer(local_message_id) ->
        case Repo.get(Messaging.Message, local_message_id) do
          %Messaging.Message{} = message ->
            {:ok, message}

          _ ->
            APHelpers.get_or_store_remote_post(comment_id)
        end

      _ ->
        APHelpers.get_or_store_remote_post(comment_id)
    end
  end

  def resolve_comment_target_message(_, _, _), do: {:error, :invalid_comment}

  defp thread_reply_local_message_id(%{"_local_message_id" => message_id})
       when is_integer(message_id),
       do: message_id

  defp thread_reply_local_message_id(%{_local_message_id: message_id})
       when is_integer(message_id),
       do: message_id

  defp thread_reply_local_message_id(%{"_local_message_id" => message_id})
       when is_binary(message_id) do
    case Integer.parse(String.trim(message_id)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp thread_reply_local_message_id(_), do: nil

  defp reactions_for_keys(reaction_map, keys) when is_map(reaction_map) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(reaction_map, key) do
        reactions when is_list(reactions) -> reactions
        _ -> nil
      end
    end) || []
  end

  defp reactions_for_keys(_, _), do: []

  defp actor_profile_path(username, domain)
       when is_binary(username) and username != "" and is_binary(domain) and domain != "" do
    ActorPaths.profile_path(username, domain)
  end

  defp actor_profile_path(_, _), do: nil

  defp parse_acct_parts(acct) when is_binary(acct) do
    cleaned =
      acct
      |> String.trim()
      |> String.trim_leading("@")

    case String.split(cleaned, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" -> {username, domain}
      [username] when username != "" -> {username, nil}
      _ -> {nil, nil}
    end
  end

  defp parse_acct_parts(_), do: {nil, nil}

  defp uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp uri_host(_), do: nil

  defp first_http_url_from_value(value) do
    value
    |> url_candidates_from_field()
    |> Enum.find_value(&normalize_http_url/1)
  end

  defp local_message_id_for_reply(replies, comment_id) when is_list(replies) do
    Enum.find_value(replies, fn reply ->
      if is_map(reply) && reply["id"] == comment_id do
        case reply["_local_message_id"] do
          id when is_integer(id) -> id
          _ -> nil
        end
      end
    end)
  end

  defp local_message_id_for_reply(_, _), do: nil

  defp local_message_id_for_ancestor(ancestors, comment_id) when is_list(ancestors) do
    Enum.find_value(ancestors, fn ancestor ->
      post = ancestor[:post] || ancestor["post"] || %{}

      post_id =
        normalize_in_reply_to_ref(map_get_value(post, "id")) ||
          normalize_in_reply_to_ref(map_get_value(post, "url"))

      if post_id == comment_id do
        ancestor_local_message_id(post)
      end
    end)
  end

  defp local_message_id_for_ancestor(_, _), do: nil

  defp collect_cached_replies(activitypub_ids) do
    do_collect_cached_replies(activitypub_ids, MapSet.new())
  end

  defp do_collect_cached_replies(activitypub_ids, seen_message_ids) do
    sanitized_ids =
      activitypub_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if Enum.empty?(sanitized_ids) do
      []
    else
      fetched = Messaging.get_cached_replies_to_activitypub_ids(sanitized_ids)

      new_messages =
        Enum.reject(fetched, fn message ->
          MapSet.member?(seen_message_ids, message.id)
        end)

      if Enum.empty?(new_messages) do
        []
      else
        next_ids =
          new_messages
          |> Enum.map(& &1.activitypub_id)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        next_seen_ids =
          Enum.reduce(new_messages, seen_message_ids, fn message, acc ->
            MapSet.put(acc, message.id)
          end)

        new_messages ++ do_collect_cached_replies(next_ids, next_seen_ids)
      end
    end
  end

  defp reply_identity_key(%{"id" => id}) when is_binary(id), do: id

  defp reply_identity_key(reply) when is_map(reply) do
    attributed_to = reply["attributedTo"] || "unknown"
    published = reply["published"] || "unknown"
    content_hash = :erlang.phash2(reply["content"] || "")
    "#{attributed_to}:#{published}:#{content_hash}"
  end

  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      Map.has_key?(map, String.to_atom(key)) ->
        Map.get(map, String.to_atom(key))

      true ->
        nil
    end
  end

  defp map_get_value(_, _), do: nil

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp normalize_http_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if String.match?(trimmed, ~r/^https?:\/\//i) do
      trimmed
    else
      nil
    end
  end

  defp normalize_http_url(_), do: nil

  defp url_candidates_from_field(nil), do: []
  defp url_candidates_from_field(url) when is_binary(url), do: [url]

  defp url_candidates_from_field(urls) when is_list(urls) do
    Enum.flat_map(urls, &url_candidates_from_field/1)
  end

  defp url_candidates_from_field(url_map) when is_map(url_map) do
    [
      map_get_value(url_map, "url"),
      map_get_value(url_map, "href"),
      map_get_value(url_map, "src")
    ]
    |> Enum.flat_map(&url_candidates_from_field/1)
  end

  defp url_candidates_from_field(_), do: []
end
