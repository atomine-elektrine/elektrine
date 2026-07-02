defmodule ElektrineWeb.API.RelationshipJSON do
  @moduledoc false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles

  def account_identifier(%User{} = account), do: to_string(account.id)
  def account_identifier(%Actor{} = actor), do: "remote:#{actor.id}"

  def embed_relationship(payload, viewer_id, account) when is_integer(viewer_id) do
    relationship = format_relationship(viewer_id, account)

    Map.update(payload, :pleroma, %{relationship: relationship}, fn extension ->
      Map.put(extension || %{}, :relationship, relationship)
    end)
  end

  def embed_relationship(payload, _viewer_id, _account), do: payload

  def format_relationship(%User{} = account, attrs), do: relationship_payload(account, attrs)
  def format_relationship(%Actor{} = account, attrs), do: relationship_payload(account, attrs)

  def format_relationship(viewer_id, %User{} = target) when is_integer(viewer_id) do
    relationship_payload(target,
      following: Profiles.following?(viewer_id, target.id),
      followed_by: Profiles.following?(target.id, viewer_id),
      muting: Accounts.user_muted?(viewer_id, target.id),
      muting_notifications: Accounts.user_muting_notifications?(viewer_id, target.id),
      blocking: Accounts.user_blocked?(viewer_id, target.id),
      blocked_by: Accounts.user_blocked?(target.id, viewer_id),
      endorsed: Accounts.account_endorsed?(viewer_id, target),
      notifying: Accounts.account_subscribed?(viewer_id, target),
      note: Accounts.account_note_comment(viewer_id, {:user, target.id})
    )
  end

  def format_relationship(viewer_id, %Actor{} = target) when is_integer(viewer_id) do
    status =
      case Profiles.remote_following_status_batch(viewer_id, [target.id]) do
        [{_actor_id, status}] -> status
        _ -> :not_following
      end

    relationship_payload(target,
      following: status == :following,
      requested: status == :pending,
      muting: Accounts.remote_actor_muted?(viewer_id, target.id),
      blocking: Accounts.remote_actor_blocked?(viewer_id, target.id),
      domain_blocking: Accounts.domain_blocked?(viewer_id, target.domain),
      endorsed: Accounts.account_endorsed?(viewer_id, target),
      notifying: Accounts.account_subscribed?(viewer_id, target),
      note: Accounts.account_note_comment(viewer_id, {:remote_actor, target.id})
    )
  end

  def format_relationship(_viewer_id, account), do: relationship_payload(account, [])

  defp relationship_payload(account, attrs) do
    %{
      id: to_string(account.id),
      following: Keyword.get(attrs, :following, false),
      followed_by: Keyword.get(attrs, :followed_by, false),
      requested: Keyword.get(attrs, :requested, false),
      muting: Keyword.get(attrs, :muting, false),
      muting_notifications: Keyword.get(attrs, :muting_notifications, false),
      blocking: Keyword.get(attrs, :blocking, false),
      blocked_by: Keyword.get(attrs, :blocked_by, false),
      domain_blocking: Keyword.get(attrs, :domain_blocking, false),
      showing_reblogs: true,
      notifying: Keyword.get(attrs, :notifying, false),
      endorsed: Keyword.get(attrs, :endorsed, false),
      note: Keyword.get(attrs, :note, "")
    }
  end
end
