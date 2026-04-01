defmodule ElektrineWeb.RemotePostLive.Threading do
  @moduledoc false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers

  def build_threaded_replies_with_actor_cache(replies, post_id, sort) do
    threaded_replies = build_reply_tree(replies, post_id, sort)
    thread_reply_actors = build_thread_reply_actor_cache(threaded_replies)
    {threaded_replies, thread_reply_actors}
  end

  def build_thread_reply_actor_cache(threaded_replies) when is_list(threaded_replies) do
    actor_uris =
      threaded_replies
      |> collect_thread_reply_actor_uris(MapSet.new())
      |> MapSet.to_list()

    if actor_uris == [] do
      %{}
    else
      Enum.reduce(actor_uris, %{}, fn uri, acc ->
        case ActivityPub.get_actor_by_uri(uri) do
          %{uri: actor_uri} = actor ->
            Map.put(acc, normalize_in_reply_to_ref(actor_uri) || uri, actor)

          _ ->
            acc
        end
      end)
    end
  end

  def build_thread_reply_actor_cache(_), do: %{}

  # Build a tree structure from flat replies based on inReplyTo or Lemmy path.
  defp build_reply_tree(replies, root_post_id, sort) do
    has_lemmy_paths =
      Enum.any?(replies, fn reply ->
        get_in(reply, ["_lemmy", "path"]) != nil
      end)

    if has_lemmy_paths do
      build_lemmy_tree(replies, sort)
    else
      build_standard_tree(replies, root_post_id, sort)
    end
  end

  defp collect_thread_reply_actor_uris([], acc), do: acc

  defp collect_thread_reply_actor_uris([node | rest], acc) when is_map(node) do
    reply = Map.get(node, :reply, %{})
    children = Map.get(node, :children, [])

    acc =
      acc
      |> maybe_add_thread_reply_actor_uri(Map.get(reply, "attributedTo"))
      |> maybe_add_thread_reply_actor_uri(Map.get(reply, "actor"))

    acc = collect_thread_reply_actor_uris(children, acc)

    collect_thread_reply_actor_uris(rest, acc)
  end

  defp collect_thread_reply_actor_uris([_ | rest], acc),
    do: collect_thread_reply_actor_uris(rest, acc)

  defp maybe_add_thread_reply_actor_uri(acc, uri) do
    case normalize_in_reply_to_ref(uri) do
      normalized when is_binary(normalized) -> MapSet.put(acc, normalized)
      _ -> acc
    end
  end

  defp sort_replies(replies, sort) do
    case sort do
      "hot" ->
        Enum.sort_by(replies, fn reply ->
          score = get_reply_score(reply)
          age_hours = get_reply_age_hours(reply)
          -(score / max(age_hours, 1))
        end)

      "top" ->
        Enum.sort_by(replies, &(-get_reply_score(&1)))

      "new" ->
        Enum.sort_by(
          replies,
          fn reply ->
            reply["published"] || ""
          end,
          :desc
        )

      "old" ->
        Enum.sort_by(
          replies,
          fn reply ->
            reply["published"] || ""
          end,
          :asc
        )

      _ ->
        replies
    end
  end

  defp get_reply_score(reply) do
    likes = APHelpers.get_collection_total(reply["likes"]) || 0
    dislikes = APHelpers.get_collection_total(reply["dislikes"]) || 0
    likes - dislikes
  end

  defp get_reply_age_hours(reply) do
    case reply["published"] do
      nil ->
        1

      date_string ->
        case DateTime.from_iso8601(date_string) do
          {:ok, datetime, _} ->
            DateTime.diff(DateTime.utc_now(), datetime, :hour) |> max(1)

          _ ->
            1
        end
    end
  end

  defp build_standard_tree(replies, root_post_id, sort) do
    children_map =
      Enum.group_by(replies, fn reply ->
        reply["inReplyTo"]
      end)

    reply_ids =
      replies
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    root_parent_ids = [root_post_id, nil, ""]

    explicit_roots =
      root_parent_ids
      |> Enum.flat_map(&Map.get(children_map, &1, []))

    orphan_roots =
      replies
      |> Enum.filter(fn reply ->
        parent_id = reply["inReplyTo"]

        parent_id not in root_parent_ids &&
          (is_nil(parent_id) ||
             (is_binary(parent_id) and not Elektrine.Strings.present?(parent_id)) ||
             !MapSet.member?(reply_ids, parent_id))
      end)

    root_replies =
      (explicit_roots ++ orphan_roots)
      |> Enum.uniq_by(&reply_identity_key/1)
      |> sort_replies(sort)

    Enum.map(root_replies, fn reply ->
      %{
        reply: reply,
        depth: 0,
        children: build_children(children_map, reply["id"], 1, sort)
      }
    end)
  end

  defp build_lemmy_tree(replies, sort) do
    {lemmy_replies, local_replies} =
      Enum.split_with(replies, fn reply ->
        get_in(reply, ["_lemmy", "path"]) != nil
      end)

    sorted_lemmy_replies =
      Enum.sort_by(lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        parts = String.split(path, ".")
        {length(parts), path}
      end)

    id_map =
      Map.new(sorted_lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        parts = String.split(path, ".")
        comment_id = List.last(parts)
        {comment_id, reply["id"]}
      end)

    lemmy_children_map =
      Enum.group_by(sorted_lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        parts = String.split(path, ".")

        case parts do
          ["0", _comment_id] ->
            :root

          ["0" | rest] when length(rest) >= 2 ->
            parent_id = Enum.at(rest, length(rest) - 2)
            Map.get(id_map, parent_id, :root)

          _ ->
            :root
        end
      end)

    local_children_map =
      Enum.group_by(local_replies, fn reply ->
        reply["inReplyTo"] || :root
      end)

    children_map =
      Map.merge(lemmy_children_map, local_children_map, fn _key, lemmy, local ->
        lemmy ++ local
      end)

    build_lemmy_children(children_map, :root, 0, sort)
  end

  defp build_lemmy_children(children_map, parent_key, depth, sort) do
    children = Map.get(children_map, parent_key, [])
    sorted_children = sort_replies(children, sort)

    Enum.map(sorted_children, fn reply ->
      nested_children = build_lemmy_children(children_map, reply["id"], depth + 1, sort)

      %{
        reply: reply,
        depth: depth,
        children: nested_children
      }
    end)
  end

  defp build_children(children_map, parent_id, depth, sort) do
    children = Map.get(children_map, parent_id, [])
    sorted_children = sort_replies(children, sort)

    Enum.map(sorted_children, fn reply ->
      nested_children = build_children(children_map, reply["id"], depth + 1, sort)

      %{
        reply: reply,
        depth: depth,
        children: nested_children
      }
    end)
  end

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)
    Elektrine.Strings.present(trimmed)
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp reply_identity_key(%{"id" => id}) when is_binary(id), do: id

  defp reply_identity_key(reply) when is_map(reply) do
    Map.get(reply, "id") ||
      Map.get(reply, "_local_message_id") ||
      Map.get(reply, "published") ||
      inspect(reply)
  end

  defp reply_identity_key(reply), do: inspect(reply)
end
