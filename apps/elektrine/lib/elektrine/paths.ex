defmodule Elektrine.Paths do
  @moduledoc false

  alias Elektrine.{Accounts, Domains}

  def post_path(%{id: id, reply_to_id: reply_to_id, conversation: %{type: "timeline"}})
      when is_integer(id) and not is_nil(reply_to_id) do
    anchored_post_path(reply_to_id, id)
  end

  def post_path(%{id: id, conversation: %{type: "timeline"}}) when is_integer(id),
    do: post_path(id)

  def post_path(%{
        id: id,
        reply_to_id: reply_to_id,
        conversation: %{type: "community", name: name}
      })
      when is_integer(id) and is_binary(name) and not is_nil(reply_to_id) do
    discussion_message_path(name, reply_to_id, id)
  end

  def post_path(%{id: id, title: title, conversation: %{type: "community", name: name}})
      when is_integer(id) and is_binary(name) do
    discussion_post_path(name, id, title)
  end

  def post_path(%{id: id, conversation: %{type: "chat", hash: hash}})
      when is_integer(id) and is_binary(hash) and hash != "" do
    chat_message_path(hash, id)
  end

  def post_path(%{id: id, conversation: %{type: "chat", id: conversation_id}})
      when is_integer(id) and is_integer(conversation_id) do
    chat_message_path(conversation_id, id)
  end

  def post_path(%{id: id}) when is_integer(id), do: post_path(id)

  def post_path(%{id: id, activitypub_id: activitypub_id})
      when is_integer(id) and is_binary(activitypub_id) and activitypub_id != "" do
    post_path(id)
  end

  def post_path(ref) when is_integer(ref), do: "/post/#{ref}"

  def post_path(ref) when is_binary(ref) do
    normalized_ref =
      ref
      |> String.trim()
      |> decode_remote_post_ref()

    case Integer.parse(normalized_ref) do
      {id, ""} -> post_path(id)
      _ when normalized_ref == "" -> nil
      _ -> remote_post_path(normalized_ref)
    end
  end

  def post_path(ref), do: post_path(to_string(ref))

  def remote_post_path(ref) when is_integer(ref), do: post_path(ref)

  def remote_post_path(ref) when is_binary(ref) do
    normalized_ref =
      ref
      |> String.trim()
      |> decode_remote_post_ref()

    case Integer.parse(normalized_ref) do
      {id, ""} -> post_path(id)
      _ when normalized_ref == "" -> nil
      _ -> "/remote/post/#{URI.encode_www_form(normalized_ref)}"
    end
  end

  def remote_post_path(ref), do: remote_post_path(to_string(ref))

  def local_post_path(ref), do: post_path(ref)

  def post_anchor(message_id) when is_integer(message_id), do: "#message-#{message_id}"

  def post_anchor(message_id) when is_binary(message_id) do
    case Integer.parse(message_id) do
      {id, ""} -> post_anchor(id)
      _ -> ""
    end
  end

  def post_anchor(_), do: ""

  def anchored_post_path(post_ref, anchor_message_id) do
    case post_path(post_ref) do
      nil -> nil
      path -> path <> post_anchor(anchor_message_id)
    end
  end

  def chat_path(%{hash: hash}) when is_binary(hash) and hash != "", do: chat_path(hash)
  def chat_path(%{id: id}) when is_integer(id), do: chat_path(id)
  def chat_path(ref) when is_integer(ref), do: "/chat/#{ref}"
  def chat_path(ref) when is_binary(ref), do: "/chat/#{URI.encode_www_form(String.trim(ref))}"
  def chat_path(ref), do: chat_path(to_string(ref))

  def chat_message_path(conversation_ref, message_id) do
    case chat_path(conversation_ref) do
      nil -> nil
      path -> path <> post_anchor(message_id)
    end
  end

  def chat_root_message_path(message_id), do: "/chat" <> post_anchor(message_id)

  def discussion_path(community_name) when is_binary(community_name) do
    "/discussions/#{URI.encode_www_form(String.trim(community_name))}"
  end

  def discussion_post_path(community_name, post_id) when is_binary(community_name) do
    discussion_path(community_name) <> "/post/#{post_id}"
  end

  def discussion_post_path(community_name, post_id, title) when is_binary(community_name) do
    slug = Elektrine.Utils.Slug.discussion_url_slug(post_id, title)
    discussion_path(community_name) <> "/p/#{slug}"
  end

  def discussion_message_path(community_name, post_id, message_id)
      when is_binary(community_name) do
    discussion_post_path(community_name, post_id) <> post_anchor(message_id)
  end

  def email_view_path(%{hash: hash}) when is_binary(hash) and hash != "",
    do: email_view_path(hash)

  def email_view_path(%{id: id}) when is_integer(id), do: email_view_path(id)
  def email_view_path(ref) when is_integer(ref), do: "/email/view/#{ref}"

  def email_view_path(ref) when is_binary(ref),
    do: "/email/view/#{URI.encode_www_form(String.trim(ref))}"

  def email_view_path(ref), do: email_view_path(to_string(ref))

  def notifications_path, do: "/notifications"
  def overview_path, do: "/overview"
  def search_path, do: "/search"
  def login_path, do: "/login"
  def register_path, do: "/register"
  def timeline_path, do: "/timeline"
  def timeline_path(params) when is_list(params), do: with_query(timeline_path(), params)
  def chat_root_path, do: "/chat"
  def chat_root_path(params) when is_list(params), do: with_query(chat_root_path(), params)
  def chat_join_path(ref), do: chat_root_path() <> "/join/" <> URI.encode_www_form(to_string(ref))
  def email_index_path, do: "/email"
  def email_index_path(params) when is_list(params), do: with_query(email_index_path(), params)
  def email_compose_path(params \\ []), do: with_query("/email/compose", params)
  def email_settings_path, do: "/email/settings"
  def friends_path, do: "/friends"
  def friends_path(params) when is_list(params), do: with_query(friends_path(), params)
  def lists_path, do: "/lists"

  def lists_path(fragment) when is_binary(fragment),
    do: lists_path() <> "#" <> String.trim_leading(fragment, "#")

  def calendar_path, do: "/calendar"
  def calendar_path(params) when is_list(params), do: with_query(calendar_path(), params)
  def discussions_path, do: "/discussions"
  def vpn_path, do: "/vpn"
  def vpn_policy_path, do: "/vpn/policy"

  def hashtag_path(hashtag) when is_binary(hashtag),
    do: "/hashtag/#{URI.encode_www_form(String.trim_leading(String.trim(hashtag), "#"))}"

  def community_path(name) when is_binary(name),
    do: "/communities/#{URI.encode_www_form(String.trim(name))}"

  def admin_path, do: "/pripyat"
  def admin_path(:users), do: "/pripyat/users"
  def admin_path(:reports), do: "/pripyat/reports"
  def admin_path(:content_moderation), do: "/pripyat/content-moderation"
  def admin_path(:chat_messages), do: "/pripyat/arblarg/messages"
  def admin_path(:communities), do: "/pripyat/communities"
  def admin_path(:vpn), do: "/pripyat/vpn"

  def admin_user_edit_path(user_id) when is_integer(user_id), do: "/pripyat/users/#{user_id}/edit"

  def admin_chat_message_path(message_id) when is_integer(message_id),
    do: "/pripyat/arblarg/messages/#{message_id}/view"

  def profile_path(handle) when is_binary(handle) do
    case parse_handle(handle) do
      {:ok, username, domain} -> profile_path(username, domain)
      :error -> nil
    end
  end

  def profile_path(%{username: username, domain: domain} = actor)
      when is_binary(username) and is_binary(domain) do
    profile_path(prefixed_username(actor), domain)
  end

  def profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    local_profile_path(username, domain) || remote_profile_path(username, domain)
  end

  def profile_path(_, _), do: nil

  def local_profile_path(handle) when is_binary(handle) do
    case parse_handle(handle) do
      {:ok, username, domain} -> local_profile_path(username, domain)
      :error -> nil
    end
  end

  def local_profile_path(%{username: username, domain: domain} = actor)
      when is_binary(username) and is_binary(domain) do
    local_profile_path(prefixed_username(actor), domain)
  end

  def local_profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    clean_username = normalize_username(username)
    clean_domain = normalize_domain(domain)

    cond do
      clean_username == "" or clean_domain == "" ->
        nil

      not Domains.local_profile_domain?(clean_domain) ->
        nil

      String.starts_with?(clean_username, "!") ->
        "/communities/#{URI.encode_www_form(String.trim_leading(clean_username, "!"))}"

      true ->
        local_user_profile_path(clean_username)
    end
  end

  def local_profile_path(_, _), do: nil

  def remote_profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    clean_username = normalize_username(username)
    clean_domain = normalize_domain(domain)

    if clean_username == "" or clean_domain == "" do
      nil
    else
      "/remote/#{clean_username}@#{clean_domain}"
    end
  end

  def remote_profile_path(_, _), do: nil

  defp local_user_profile_path(username) do
    case Accounts.get_user_by_username_or_handle(username) do
      %{handle: handle} when is_binary(handle) and handle != "" ->
        "/#{URI.encode_www_form(handle)}"

      %{username: canonical_username}
      when is_binary(canonical_username) and canonical_username != "" ->
        "/#{URI.encode_www_form(canonical_username)}"

      _ ->
        "/#{URI.encode_www_form(username)}"
    end
  end

  defp parse_handle(handle) do
    cleaned = handle |> String.trim() |> String.trim_leading("@")

    case String.split(cleaned, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" ->
        {:ok, normalize_username(username), normalize_domain(domain)}

      _ ->
        :error
    end
  end

  defp prefixed_username(%{actor_type: "Group", username: username}) when is_binary(username) do
    if String.starts_with?(username, "!"), do: username, else: "!" <> username
  end

  defp prefixed_username(%{username: username}), do: username

  defp normalize_username(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
  end

  defp decode_remote_post_ref(ref) when is_binary(ref) do
    URI.decode_www_form(ref)
  rescue
    ArgumentError -> ref
  end

  defp with_query(path, params) when is_binary(path) and is_list(params) do
    query = URI.encode_query(params)
    if query == "", do: path, else: path <> "?" <> query
  end
end
