defmodule ElektrineSocialWeb.Components.Social.TimelinePostAncestors do
  @moduledoc false

  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  def resolve_for_post(post, source, resolve_reply_refs) when is_map(post) do
    max_depth = reply_ancestor_max_depth(source)
    should_resolve_refs = should_resolve_reply_refs?(source, resolve_reply_refs)
    allow_db_lookups = allow_ancestor_db_lookups?(source)

    cache_key =
      {
        source || "timeline",
        max_depth,
        should_resolve_refs,
        allow_db_lookups,
        Map.get(post, :id),
        Map.get(post, :reply_to_id),
        Map.get(post, :activitypub_id),
        Map.get(post, :activitypub_url),
        metadata_in_reply_to(post),
        Map.get(post, :updated_at),
        Map.get(post, :edited_at)
      }

    cache = Process.get(:timeline_post_reply_ancestor_cache, %{})

    case Map.fetch(cache, cache_key) do
      {:ok, ancestors} ->
        ancestors

      :error ->
        ancestors =
          resolve_reply_ancestors(post, should_resolve_refs, max_depth, allow_db_lookups)

        next_cache =
          cache
          |> maybe_reset_reply_ancestor_cache()
          |> Map.put(cache_key, ancestors)

        Process.put(:timeline_post_reply_ancestor_cache, next_cache)
        ancestors
    end
  end

  def resolve_for_post(_, _, _), do: []

  def author_subtitle(ancestor) when is_map(ancestor) do
    cond do
      is_map(ancestor.local_sender) ->
        "@#{ancestor.local_sender.handle || ancestor.local_sender.username}@#{Elektrine.Domains.default_user_handle_domain()}"

      is_map(ancestor.remote_actor) ->
        "@#{ancestor.remote_actor.username}@#{ancestor.remote_actor.domain}"

      is_binary(ancestor.activitypub_ref) ->
        case URI.parse(ancestor.activitypub_ref) do
          %{host: host} when is_binary(host) and host != "" -> "on #{host}"
          _ -> nil
        end

      true ->
        nil
    end
  end

  def author_subtitle(_), do: nil

  def clickable?(%{click_event: event, click_url: url})
      when is_binary(event) and event != "" and is_binary(url) and url != "",
      do: true

  def clickable?(%{click_event: event, click_id: id})
      when is_binary(event) and event != "" and not is_nil(id),
      do: true

  def clickable?(_), do: false

  def click_attrs(%{click_event: event} = ancestor) when is_binary(event) and event != "" do
    [{"phx-click", event}]
    |> Kernel.++(optional_click_attr("phx-value-id", Map.get(ancestor, :click_id)))
    |> Kernel.++(optional_click_attr("phx-value-url", Map.get(ancestor, :click_url)))
  end

  def click_attrs(_), do: []

  def author_class(:federated), do: "text-primary"
  def author_class(:local), do: "text-error"
  def author_class(:external), do: "text-secondary"
  def author_class(_), do: ""

  # Keep reply ancestor lookups cheap on high-volume feeds.
  defp reply_ancestor_max_depth(source)
       when source in ["timeline", "portal", "hashtag", "remote_profile"],
       do: 3

  defp reply_ancestor_max_depth(_), do: 8

  # External reference resolution can be expensive and is not required for feed readability.
  defp should_resolve_reply_refs?(source, _resolve_reply_refs)
       when source in ["timeline", "portal", "hashtag", "remote_profile"] do
    false
  end

  defp should_resolve_reply_refs?(_source, resolve_reply_refs), do: resolve_reply_refs

  # Keep feed rendering free of synchronous database lookups.
  defp allow_ancestor_db_lookups?(_source), do: false

  defp maybe_reset_reply_ancestor_cache(cache) when is_map(cache) do
    if map_size(cache) >= 256 do
      %{}
    else
      cache
    end
  end

  defp resolve_reply_ancestors(post, resolve_reply_refs, max_depth, allow_db_lookups)

  defp resolve_reply_ancestors(post, resolve_reply_refs, max_depth, allow_db_lookups)
       when is_map(post) and max_depth > 0 do
    {initial_message, initial_ref, initial_author, initial_content} =
      ancestor_seed(post, resolve_reply_refs, allow_db_lookups)

    do_resolve_reply_ancestors(
      initial_message,
      initial_ref,
      initial_author,
      initial_content,
      [],
      MapSet.new(),
      max_depth,
      resolve_reply_refs,
      allow_db_lookups
    )
  end

  defp resolve_reply_ancestors(_, _, _, _), do: []

  defp do_resolve_reply_ancestors(
         _,
         _,
         _,
         _,
         acc,
         _seen,
         depth,
         _resolve_reply_refs,
         _allow_db_lookups
       )
       when depth <= 0,
       do: acc

  defp do_resolve_reply_ancestors(
         nil,
         nil,
         _fallback_author,
         _fallback_content,
         acc,
         _seen,
         _depth,
         _resolve_reply_refs,
         _allow_db_lookups
       ),
       do: acc

  defp do_resolve_reply_ancestors(
         message,
         ref,
         fallback_author,
         fallback_content,
         acc,
         seen,
         depth,
         resolve_reply_refs,
         allow_db_lookups
       ) do
    message =
      preload_or_resolve_ancestor_message(
        message,
        ref,
        resolve_reply_refs,
        allow_db_lookups
      )

    seen_key = ancestor_seen_key(message, ref)

    cond do
      is_nil(seen_key) ->
        acc

      MapSet.member?(seen, seen_key) ->
        acc

      true ->
        entry =
          build_reply_ancestor_entry(
            message,
            ref,
            fallback_author,
            fallback_content,
            allow_db_lookups
          )

        {next_message, next_ref, next_author, next_content} =
          next_ancestor_state(message, resolve_reply_refs, allow_db_lookups)

        next_acc =
          if entry do
            [entry | acc]
          else
            acc
          end

        do_resolve_reply_ancestors(
          next_message,
          next_ref,
          next_author,
          next_content,
          next_acc,
          MapSet.put(seen, seen_key),
          depth - 1,
          resolve_reply_refs,
          allow_db_lookups
        )
    end
  end

  defp ancestor_seed(post, resolve_reply_refs, allow_db_lookups) do
    metadata_ref = metadata_in_reply_to(post)
    metadata_author = metadata_in_reply_to_author(post)
    metadata_content = metadata_in_reply_to_content(post)

    loaded_reply =
      if Map.has_key?(post, :reply_to) && assoc_loaded_map?(post.reply_to),
        do: post.reply_to,
        else: nil

    local_parent_id = normalize_local_id(Map.get(post, :reply_to_id))

    cond do
      is_map(loaded_reply) ->
        {preload_ancestor_message(loaded_reply, allow_db_lookups), metadata_ref, metadata_author,
         metadata_content}

      allow_db_lookups && is_integer(local_parent_id) ->
        {fetch_local_ancestor(local_parent_id), metadata_ref, metadata_author, metadata_content}

      allow_db_lookups && resolve_reply_refs && is_binary(metadata_ref) ->
        {resolve_ancestor_ref(metadata_ref), metadata_ref, metadata_author, metadata_content}

      is_binary(metadata_ref) ->
        {nil, metadata_ref, metadata_author, metadata_content}

      true ->
        {nil, nil, nil, nil}
    end
  end

  defp preload_or_resolve_ancestor_message(message, _ref, _resolve_reply_refs, allow_db_lookups)
       when is_map(message),
       do: preload_ancestor_message(message, allow_db_lookups)

  defp preload_or_resolve_ancestor_message(nil, ref, true, true) when is_binary(ref),
    do: resolve_ancestor_ref(ref)

  defp preload_or_resolve_ancestor_message(_, _, _, _), do: nil

  defp next_ancestor_state(message, resolve_reply_refs, allow_db_lookups) when is_map(message) do
    metadata_ref = metadata_in_reply_to(message)
    metadata_author = metadata_in_reply_to_author(message)
    metadata_content = metadata_in_reply_to_content(message)

    loaded_parent =
      if Map.has_key?(message, :reply_to) && assoc_loaded_map?(message.reply_to) do
        preload_ancestor_message(message.reply_to, allow_db_lookups)
      else
        nil
      end

    local_parent_id = normalize_local_id(Map.get(message, :reply_to_id))

    local_parent =
      if allow_db_lookups && is_nil(loaded_parent) && is_integer(local_parent_id) do
        fetch_local_ancestor(local_parent_id)
      else
        nil
      end

    resolved_parent =
      if allow_db_lookups && is_nil(loaded_parent) && is_nil(local_parent) && resolve_reply_refs &&
           is_binary(metadata_ref) do
        resolve_ancestor_ref(metadata_ref)
      else
        nil
      end

    {loaded_parent || local_parent || resolved_parent, metadata_ref, metadata_author,
     metadata_content}
  end

  defp next_ancestor_state(_, _, _), do: {nil, nil, nil, nil}

  defp build_reply_ancestor_entry(
         message,
         ref,
         fallback_author,
         fallback_content,
         allow_db_lookups
       ) do
    local_id =
      if is_map(message) do
        normalize_local_id(Map.get(message, :id))
      else
        nil
      end

    activitypub_ref =
      if is_map(message) do
        normalize_in_reply_to_ref(Map.get(message, :activitypub_id)) ||
          normalize_in_reply_to_ref(Map.get(message, :activitypub_url)) ||
          normalize_in_reply_to_ref(ref)
      else
        normalize_in_reply_to_ref(ref)
      end

    {click_event, click_url, click_id} =
      cond do
        is_integer(local_id) ->
          {"navigate_to_post", nil, local_id}

        is_binary(activitypub_ref) ->
          {"navigate_to_remote_post", activitypub_ref, nil}

        true ->
          {nil, nil, nil}
      end

    author_info = ancestor_author_info(message, fallback_author, activitypub_ref)

    preview_content =
      ancestor_preview_content(message, fallback_content) ||
        local_ancestor_preview_content(activitypub_ref, allow_db_lookups)

    instance_domain = ancestor_instance_domain(message, activitypub_ref)

    local_sender =
      if(is_map(message) && assoc_loaded_map?(Map.get(message, :sender)),
        do: message.sender,
        else: nil
      )

    remote_actor =
      if(is_map(message) && assoc_loaded_map?(Map.get(message, :remote_actor)),
        do: message.remote_actor,
        else: nil
      )

    interaction_keys =
      [
        normalize_in_reply_to_ref(
          if(is_map(message), do: Map.get(message, :activitypub_id), else: nil)
        ),
        if(is_integer(local_id), do: to_string(local_id), else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    has_payload =
      is_integer(local_id) ||
        is_binary(activitypub_ref) ||
        is_binary(preview_content) ||
        author_info.name != "a post"

    if has_payload do
      %{
        local_id: local_id,
        click_event: click_event,
        click_url: click_url,
        click_id: click_id,
        author_info: author_info,
        activitypub_ref: activitypub_ref,
        preview_content: preview_content,
        instance_domain: instance_domain,
        local_sender: local_sender,
        remote_actor: remote_actor,
        like_count: if(is_map(message), do: Map.get(message, :like_count, 0) || 0, else: 0),
        boost_count: if(is_map(message), do: Map.get(message, :share_count, 0) || 0, else: 0),
        reply_count: if(is_map(message), do: Map.get(message, :reply_count, 0) || 0, else: 0),
        interaction_keys: interaction_keys
      }
    else
      nil
    end
  end

  defp ancestor_author_info(message, fallback_author, activitypub_ref) when is_map(message) do
    cond do
      assoc_loaded_map?(Map.get(message, :remote_actor)) ->
        remote_actor = message.remote_actor
        %{name: "@#{remote_actor.username}@#{remote_actor.domain}", type: :federated}

      assoc_loaded_map?(Map.get(message, :sender)) ->
        sender = message.sender

        %{
          name:
            "@#{sender.handle || sender.username}@#{Elektrine.Domains.default_user_handle_domain()}",
          type: :local
        }

      is_binary(fallback_author) ->
        normalize_reply_author_info(fallback_author, activitypub_ref)

      is_binary(activitypub_ref) ->
        %{name: infer_reply_label_from_url(activitypub_ref) || "a post", type: :external}

      true ->
        %{name: "a post", type: :unknown}
    end
  end

  defp ancestor_author_info(_message, fallback_author, activitypub_ref)
       when is_binary(fallback_author) do
    normalize_reply_author_info(fallback_author, activitypub_ref)
  end

  defp ancestor_author_info(_message, _fallback_author, activitypub_ref)
       when is_binary(activitypub_ref) do
    %{name: infer_reply_label_from_url(activitypub_ref) || "a post", type: :external}
  end

  defp ancestor_author_info(_, _, _), do: %{name: "a post", type: :unknown}

  defp ancestor_preview_content(message, fallback_content) when is_map(message) do
    message_content = Map.get(message, :content)

    cond do
      Elektrine.Strings.present?(message_content) ->
        message_content

      Elektrine.Strings.present?(fallback_content) ->
        fallback_content

      true ->
        nil
    end
  end

  defp ancestor_preview_content(_, fallback_content)
       when is_binary(fallback_content),
       do:
         if(Elektrine.Strings.present?(fallback_content),
           do: fallback_content,
           else: nil
         )

  defp ancestor_preview_content(_, _), do: nil

  defp local_ancestor_preview_content(activitypub_ref, true) when is_binary(activitypub_ref) do
    case Messaging.get_message_by_activitypub_ref(activitypub_ref) do
      %Message{} = message ->
        ancestor_preview_content(message, nil)

      _ ->
        nil
    end
  end

  defp local_ancestor_preview_content(_, _), do: nil

  defp ancestor_instance_domain(message, _activitypub_ref) when is_map(message),
    do: PostUtilities.get_instance_domain(message)

  defp ancestor_instance_domain(_, activitypub_ref) when is_binary(activitypub_ref) do
    case URI.parse(activitypub_ref) do
      %{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp ancestor_instance_domain(_, _), do: nil

  defp ancestor_seen_key(message, _ref) when is_map(message) do
    cond do
      is_integer(Map.get(message, :id)) ->
        {:id, message.id}

      is_binary(Map.get(message, :activitypub_id)) ->
        {:ap, message.activitypub_id}

      true ->
        nil
    end
  end

  defp ancestor_seen_key(_, ref) when is_binary(ref), do: {:ref, ref}
  defp ancestor_seen_key(_, _), do: nil

  defp resolve_ancestor_ref(ref) when is_binary(ref) do
    cached_ancestor_message({:ref, ref}, fn ->
      ref
      |> Messaging.get_message_by_activitypub_ref()
      |> preload_ancestor_message()
    end)
  end

  defp fetch_local_ancestor(id) when is_integer(id) do
    cached_ancestor_message({:id, id}, fn ->
      Message
      |> Repo.get(id)
      |> preload_ancestor_message()
    end)
  end

  defp preload_ancestor_message(%Message{} = message), do: preload_ancestor_message(message, true)
  defp preload_ancestor_message(message) when is_map(message), do: message

  defp preload_ancestor_message(%Message{} = message, allow_db_lookups)
       when is_boolean(allow_db_lookups) do
    if ancestor_associations_loaded?(message) do
      message
    else
      if allow_db_lookups do
        Repo.preload(message, [:sender, :remote_actor, :reply_to], force: false)
      else
        message
      end
    end
  end

  defp preload_ancestor_message(message, _allow_db_lookups) when is_map(message), do: message

  defp ancestor_associations_loaded?(%Message{} = message) do
    Ecto.assoc_loaded?(Map.get(message, :sender)) &&
      Ecto.assoc_loaded?(Map.get(message, :remote_actor)) &&
      Ecto.assoc_loaded?(Map.get(message, :reply_to))
  end

  defp cached_ancestor_message(cache_key, loader) when is_function(loader, 0) do
    cache = Process.get(:timeline_post_ancestor_message_cache, %{})

    case Map.fetch(cache, cache_key) do
      {:ok, message} ->
        message

      :error ->
        message = loader.()

        next_cache =
          cache
          |> maybe_reset_ancestor_message_cache()
          |> Map.put(cache_key, message)

        Process.put(:timeline_post_ancestor_message_cache, next_cache)
        message
    end
  end

  defp maybe_reset_ancestor_message_cache(cache) when is_map(cache) do
    if map_size(cache) >= 512 do
      %{}
    else
      cache
    end
  end

  defp assoc_loaded_map?(%Ecto.Association.NotLoaded{}), do: false
  defp assoc_loaded_map?(value) when is_map(value), do: true
  defp assoc_loaded_map?(_), do: false

  defp metadata_in_reply_to(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      [
        Map.get(metadata, "inReplyTo"),
        Map.get(metadata, "in_reply_to"),
        Map.get(metadata, :inReplyTo),
        Map.get(metadata, :in_reply_to)
      ]
      |> Enum.find_value(&normalize_in_reply_to_ref/1)
    else
      nil
    end
  end

  defp metadata_in_reply_to(_), do: nil

  defp metadata_in_reply_to_author(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      Map.get(metadata, "inReplyToAuthor") ||
        Map.get(metadata, "in_reply_to_author") ||
        Map.get(metadata, :inReplyToAuthor) ||
        Map.get(metadata, :in_reply_to_author)
    else
      nil
    end
  end

  defp metadata_in_reply_to_author(_), do: nil

  defp metadata_in_reply_to_content(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      Map.get(metadata, "inReplyToContent") ||
        Map.get(metadata, "in_reply_to_content") ||
        Map.get(metadata, :inReplyToContent) ||
        Map.get(metadata, :in_reply_to_content)
    else
      nil
    end
  end

  defp metadata_in_reply_to_content(_), do: nil

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp normalize_local_id(value) when is_integer(value), do: value

  defp normalize_local_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_local_id(_), do: nil

  defp normalize_reply_author_info(author, in_reply_to_url) when is_binary(author) do
    author = String.trim(author)
    inferred_label = infer_reply_label_from_url(in_reply_to_url)

    cond do
      not Elektrine.Strings.present?(author) ->
        %{name: "a post", type: :unknown}

      String.starts_with?(author, "@") ->
        %{name: author, type: :federated}

      String.starts_with?(author, "someone on ") ->
        %{
          name:
            inferred_label || "a post on " <> String.replace_prefix(author, "someone on ", ""),
          type: :external
        }

      String.starts_with?(author, "a post on ") ->
        %{name: inferred_label || author, type: :external}

      String.starts_with?(author, "post ") && String.contains?(author, " on ") ->
        %{name: author, type: :external}

      String.starts_with?(author, "http://") || String.starts_with?(author, "https://") ->
        %{name: infer_reply_label_from_url(author) || "a post", type: :external}

      true ->
        %{name: author, type: :federated}
    end
  end

  defp infer_reply_label_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(host) and is_binary(path) ->
        case infer_username_from_reply_path(path) do
          username when is_binary(username) ->
            "@#{username}@#{host}"

          _ ->
            case infer_post_id_from_reply_path(path) do
              post_id when is_binary(post_id) -> "post #{post_id} on #{host}"
              _ -> "a post on #{host}"
            end
        end

      %{host: host} when is_binary(host) and host != "" ->
        "a post on #{host}"

      _ ->
        nil
    end
  end

  defp infer_reply_label_from_url(_), do: nil

  defp infer_username_from_reply_path(path) when is_binary(path) do
    case reply_path_segments(path) do
      ["users", username | _] ->
        trim_reply_identifier(username)

      ["u", username | _] ->
        trim_reply_identifier(username)

      [segment | _] ->
        if String.starts_with?(segment, "@"), do: trim_reply_identifier(segment), else: nil

      _ ->
        nil
    end
  end

  defp infer_post_id_from_reply_path(path) when is_binary(path) do
    candidate =
      case reply_path_segments(path) do
        ["users", _username, "statuses", post_id | _] -> post_id
        ["notice", post_id | _] -> post_id
        ["objects", post_id | _] -> post_id
        ["posts", post_id | _] -> post_id
        ["post", post_id | _] -> post_id
        ["comments", post_id | _] -> post_id
        ["comment", post_id | _] -> post_id
        [first, post_id | _] -> if String.starts_with?(first, "@"), do: post_id, else: nil
        _ -> nil
      end

    trim_reply_identifier(candidate)
  end

  defp reply_path_segments(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim_reply_identifier(value) when is_binary(value) do
    value
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_reply_identifier(_), do: nil

  defp optional_click_attr(name, value) when is_binary(value) and value != "",
    do: [{name, value}]

  defp optional_click_attr(name, value) when is_integer(value),
    do: [{name, value}]

  defp optional_click_attr(_name, _value), do: []
end
