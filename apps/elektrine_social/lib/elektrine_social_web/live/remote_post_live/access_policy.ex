defmodule ElektrineSocialWeb.RemotePostLive.AccessPolicy do
  @moduledoc false

  alias Elektrine.ActivityPub.Visibility
  alias Elektrine.Friends
  alias Elektrine.Profiles

  def current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])

  def can_view_remote_post?(post_object, local_message, current_user) do
    cond do
      match?(%{deleted_at: %DateTime{}}, local_message) ->
        false

      is_map(local_message) ->
        can_view_local_post?(local_message, current_user) ||
          remote_post_publicly_visible?(post_object)

      true ->
        remote_post_publicly_visible?(post_object)
    end
  end

  def can_view_local_post?(message, current_user) do
    viewer_id = current_user && current_user.id
    owner? = not is_nil(message.sender_id) and viewer_id == message.sender_id
    approved? = message.approval_status in ["approved", nil]

    visible? =
      case message.visibility do
        "public" ->
          true

        "unlisted" ->
          true

        "followers" ->
          owner? or (is_integer(viewer_id) and Profiles.following?(viewer_id, message.sender_id))

        "friends" ->
          owner? or (is_integer(viewer_id) and Friends.are_friends?(viewer_id, message.sender_id))

        "private" ->
          owner?

        _ ->
          false
      end

    visible? and is_nil(message.deleted_at) and (approved? or owner?)
  end

  def remote_post_publicly_visible?(post_object) when is_map(post_object) do
    Visibility.publicly_addressed?(%{
      "to" => post_object |> Map.get("to", []) |> List.wrap() |> Enum.map(&normalize_ref/1),
      "cc" => post_object |> Map.get("cc", []) |> List.wrap() |> Enum.map(&normalize_ref/1)
    })
  end

  def remote_post_publicly_visible?(_), do: false

  def robots_for_local_post(%{visibility: "public", is_draft: draft}) when draft != true,
    do: "index, follow"

  def robots_for_local_post(_), do: "noindex, nofollow"

  def robots_for_remote_post(post_object) when is_map(post_object) do
    if Visibility.indexable?(post_object), do: "index, follow", else: "noindex, nofollow"
  end

  def robots_for_remote_post(_), do: "noindex, nofollow"

  def cached_message_indexable?(%{visibility: "public", is_draft: draft}) when draft != true,
    do: true

  def cached_message_indexable?(_), do: false

  defp normalize_ref(%{"id" => id}), do: normalize_ref(id)
  defp normalize_ref(%{"href" => href}), do: normalize_ref(href)
  defp normalize_ref(%{id: id}), do: normalize_ref(id)
  defp normalize_ref(%{href: href}), do: normalize_ref(href)
  defp normalize_ref([first | _]), do: normalize_ref(first)

  defp normalize_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_ref(_), do: nil
end
