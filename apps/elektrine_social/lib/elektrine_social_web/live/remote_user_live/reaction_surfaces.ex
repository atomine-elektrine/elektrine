defmodule ElektrineSocialWeb.RemoteUserLive.ReactionSurfaces do
  @moduledoc """
  Reaction and reply-preview render helpers for the remote user profile.

  Builds the reaction surfaces (target id, value name, reactions) and reply
  author previews used by the profile template.
  """

  alias Elektrine.AccountIdentifiers
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias ElektrineSocialWeb.RemotePostLive.SurfaceHelpers
  alias ElektrineSocialWeb.RemoteUserLive.PostState
  alias ElektrineWeb.Live.PostInteractions

  def normalize_post_reaction_keys(reactions_map) when is_map(reactions_map) do
    Enum.into(reactions_map, %{}, fn {key, reactions} ->
      {PostInteractions.normalize_key(key), reactions}
    end)
  end

  def normalize_post_reaction_keys(_), do: %{}

  def reactions_for_entry(%{id: id} = post, post_reactions) when is_integer(id) do
    keys =
      PostState.local_message_state_keys(post)
      |> Enum.reject(&is_nil/1)

    reactions_for_keys(post_reactions, keys)
  end

  def reactions_for_entry(_, _), do: []

  def post_reaction_surface(post_ref, local_posts, post_reactions) do
    {target_id, value_name, keys} = reaction_target_for_post_ref(post_ref, local_posts)

    %{
      target_id: target_id,
      value_name: value_name,
      reactions: reactions_for_keys(post_reactions, keys)
    }
  end

  def reply_reaction_surface(reply, local_posts, post_reactions) when is_map(reply) do
    reply_id = Map.get(reply, "id") || Map.get(reply, :id)
    local_message_id = Map.get(reply, "_local_message_id") || Map.get(reply, :_local_message_id)

    {target_id, value_name, keys} =
      case PostState.parse_local_message_id(local_message_id) do
        {:ok, id} ->
          reply_ref =
            if is_binary(reply_id) and reply_id != "" do
              reply_id
            else
              nil
            end

          {id, "message_id", [Integer.to_string(id), id, reply_ref]}

        :error ->
          reaction_target_for_post_ref(reply_id, local_posts)
      end

    %{
      target_id: target_id,
      value_name: value_name,
      reactions: reactions_for_keys(post_reactions, keys)
    }
  end

  def reply_reaction_surface(_, _local_posts, _post_reactions) do
    %{target_id: nil, value_name: "post_id", reactions: []}
  end

  def preview_reply_author(reply) when is_map(reply) do
    local_user = Map.get(reply, "_local_user") || Map.get(reply, :_local_user)

    if is_map(local_user) do
      username = Map.get(local_user, :username) || Map.get(local_user, "username")
      handle = Map.get(local_user, :handle) || Map.get(local_user, "handle") || username
      avatar = Map.get(local_user, :avatar) || Map.get(local_user, "avatar")

      avatar_url =
        if Elektrine.Strings.present?(avatar) do
          Elektrine.Uploads.avatar_url(avatar)
        else
          nil
        end

      %{
        label: AccountIdentifiers.at_local_handle(handle),
        avatar_url: avatar_url,
        profile_path: if(is_binary(handle) && handle != "", do: "/#{handle}", else: nil)
      }
    else
      author_uri =
        Map.get(reply, "attributedTo") || Map.get(reply, :attributedTo) ||
          Map.get(reply, "actor") || Map.get(reply, :actor)

      fallback = SurfaceHelpers.build_reply_author_fallback(reply, author_uri)

      label =
        cond do
          Elektrine.Strings.present?(fallback.acct_label) ->
            fallback.acct_label

          Elektrine.Strings.present?(author_uri) ->
            "@#{APHelpers.extract_username_from_uri(author_uri)}"

          true ->
            "Remote user"
        end

      %{
        label: label,
        avatar_url: fallback.avatar_url,
        profile_path: fallback.profile_path
      }
    end
  end

  def preview_reply_author(_), do: %{label: "Remote user", avatar_url: nil, profile_path: nil}

  defp reaction_target_for_post_ref(post_ref, local_posts) do
    decoded_ref = PostState.decode_post_ref(post_ref)

    case PostState.parse_local_message_id(decoded_ref) do
      {:ok, local_id} ->
        {
          local_id,
          "message_id",
          [Integer.to_string(local_id), local_id, to_string(decoded_ref)]
        }

      :error ->
        normalized_ref =
          if is_binary(decoded_ref), do: String.trim(decoded_ref), else: to_string(decoded_ref)

        local_match =
          Enum.find(local_posts || [], fn
            %{activitypub_id: activitypub_id} -> activitypub_id == normalized_ref
            _ -> false
          end)

        case local_match do
          %{id: local_id} when is_integer(local_id) ->
            {local_id, "message_id", [normalized_ref, Integer.to_string(local_id), local_id]}

          _ when is_binary(normalized_ref) and normalized_ref != "" ->
            {normalized_ref, "post_id", [normalized_ref]}

          _ ->
            {nil, "post_id", []}
        end
    end
  end

  defp reactions_for_keys(post_reactions, keys) when is_map(post_reactions) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(post_reactions, key) do
        reactions when is_list(reactions) -> reactions
        _ -> nil
      end
    end) || []
  end

  defp reactions_for_keys(_, _), do: []
end
