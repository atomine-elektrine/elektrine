defmodule Elektrine.ActivityPub.UndoResolver do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Activity, Actor, GroupFollow}
  alias Elektrine.Messaging.{FederatedBoost, FederatedDislike, FederatedLike}
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  @undoable_activity_types ~w(Follow Like Dislike EmojiReact Announce Block)

  def resolve(activity_id, actor_uri)
      when is_binary(activity_id) and activity_id != "" and is_binary(actor_uri) and
             actor_uri != "" do
    case resolve_stored_activity(activity_id, actor_uri) ||
           resolve_follow(activity_id, actor_uri) ||
           resolve_group_follow(activity_id, actor_uri) ||
           resolve_reaction_activity(FederatedLike, "Like", activity_id, actor_uri) ||
           resolve_reaction_activity(FederatedDislike, "Dislike", activity_id, actor_uri) ||
           resolve_reaction_activity(FederatedBoost, "Announce", activity_id, actor_uri) do
      nil -> :not_found
      object -> {:ok, object}
    end
  end

  def resolve(_activity_id, _actor_uri), do: :not_found

  defp resolve_stored_activity(activity_id, actor_uri) do
    case Repo.get_by(Activity, activity_id: activity_id, local: false) do
      %Activity{activity_type: type, actor_uri: stored_actor_uri, data: data}
      when type in @undoable_activity_types and is_map(data) ->
        if same_actor?(stored_actor_uri, actor_uri) do
          data
          |> Map.put_new("id", activity_id)
          |> Map.put_new("type", type)
        end

      _ ->
        nil
    end
  end

  defp resolve_follow(activity_id, actor_uri) do
    case Repo.one(
           from(f in Follow,
             join: ra in Actor,
             on: ra.id == f.remote_actor_id,
             join: u in User,
             on: u.id == f.followed_id,
             where: f.activitypub_id == ^activity_id and ra.uri == ^actor_uri,
             select: %{id: f.activitypub_id, username: u.username}
           )
         ) do
      nil ->
        nil

      %{id: id, username: username} ->
        %{
          "type" => "Follow",
          "id" => id,
          "object" => "#{ActivityPub.instance_url()}/users/#{username}"
        }
    end
  end

  defp resolve_group_follow(activity_id, actor_uri) do
    case Repo.one(
           from(f in GroupFollow,
             join: ra in Actor,
             on: ra.id == f.remote_actor_id,
             join: ga in Actor,
             on: ga.id == f.group_actor_id,
             where: f.activitypub_id == ^activity_id and ra.uri == ^actor_uri,
             select: %{id: f.activitypub_id, object: ga.uri}
           )
         ) do
      nil ->
        nil

      %{id: id, object: object_uri} ->
        %{
          "type" => "Follow",
          "id" => id,
          "object" => object_uri
        }
    end
  end

  defp resolve_reaction_activity(schema, type, activity_id, actor_uri) do
    case Repo.one(
           from(r in schema,
             join: ra in Actor,
             on: ra.id == r.remote_actor_id,
             join: m in Message,
             on: m.id == r.message_id,
             where: r.activitypub_id == ^activity_id and ra.uri == ^actor_uri,
             select: %{
               id: r.activitypub_id,
               message_id: m.id,
               message_activitypub_id: m.activitypub_id,
               message_activitypub_url: m.activitypub_url
             }
           )
         ) do
      nil ->
        nil

      record ->
        %{
          "type" => type,
          "id" => record.id,
          "object" => target_object_uri(record)
        }
    end
  end

  defp target_object_uri(%{message_activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "" do
    activitypub_id
  end

  defp target_object_uri(%{message_activitypub_url: activitypub_url})
       when is_binary(activitypub_url) and activitypub_url != "" do
    activitypub_url
  end

  defp target_object_uri(%{message_id: message_id}) do
    "#{ActivityPub.instance_url()}/posts/#{message_id}"
  end

  defp same_actor?(left, right) do
    normalized_left = normalize_ref(left)
    normalized_right = normalize_ref(right)

    not is_nil(normalized_left) and normalized_left == normalized_right
  end

  defp normalize_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_ref(_), do: nil
end
