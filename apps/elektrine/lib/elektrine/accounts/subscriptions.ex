defmodule Elektrine.Accounts.Subscriptions do
  @moduledoc """
  Per-account notification subscriptions.
  """

  import Ecto.Query

  alias Elektrine.Accounts.{AccountSubscription, User}
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  def subscribe_to_account(user_id, %User{id: user_id}), do: {:error, :self_subscribe}

  def subscribe_to_account(user_id, %User{} = account) when is_integer(user_id) do
    attrs = %{user_id: user_id, subscribed_user_id: account.id}

    case Repo.get_by(AccountSubscription, attrs) do
      %AccountSubscription{} = subscription -> {:ok, subscription}
      nil -> insert_subscription(attrs)
    end
  end

  def subscribe_to_account(user_id, %Actor{} = actor) when is_integer(user_id) do
    attrs = %{user_id: user_id, remote_actor_id: actor.id}

    case Repo.get_by(AccountSubscription, attrs) do
      %AccountSubscription{} = subscription -> {:ok, subscription}
      nil -> insert_subscription(attrs)
    end
  end

  def subscribe_to_account(_user_id, _account), do: {:error, :invalid_account}

  def unsubscribe_from_account(user_id, %User{} = account) when is_integer(user_id) do
    delete_subscription(user_id, subscribed_user_id: account.id)
  end

  def unsubscribe_from_account(user_id, %Actor{} = actor) when is_integer(user_id) do
    delete_subscription(user_id, remote_actor_id: actor.id)
  end

  def unsubscribe_from_account(_user_id, _account), do: {:error, :invalid_account}

  def account_subscribed?(user_id, %User{} = account) when is_integer(user_id) do
    subscription_exists?(user_id, subscribed_user_id: account.id)
  end

  def account_subscribed?(user_id, %Actor{} = actor) when is_integer(user_id) do
    subscription_exists?(user_id, remote_actor_id: actor.id)
  end

  def account_subscribed?(_user_id, _account), do: false

  def notify_subscribers_for_message(%Message{} = message) do
    message = Repo.preload(message, [:sender, :remote_actor, :conversation])

    if notifiable_message?(message) do
      message
      |> subscribed_user_ids()
      |> Enum.each(&create_status_notification(&1, message))
    end

    :ok
  end

  def notify_subscribers_for_message(_message), do: :ok

  defp insert_subscription(attrs) do
    %AccountSubscription{}
    |> AccountSubscription.changeset(attrs)
    |> Repo.insert()
  end

  defp delete_subscription(user_id, clauses) do
    case get_subscription(user_id, clauses) do
      %AccountSubscription{} = subscription -> Repo.delete(subscription)
      nil -> {:ok, :not_subscribed}
    end
  end

  defp subscription_exists?(user_id, clauses) do
    not is_nil(get_subscription(user_id, clauses))
  end

  defp get_subscription(user_id, clauses) do
    clauses
    |> Keyword.put(:user_id, user_id)
    |> then(&Repo.get_by(AccountSubscription, &1))
  end

  defp notifiable_message?(
         %Message{deleted_at: nil, is_draft: draft, conversation: conversation} =
           message
       ) do
    draft != true and social_message?(message, conversation)
  end

  defp notifiable_message?(_message), do: false

  defp social_message?(%Message{federated: true}, _conversation), do: true
  defp social_message?(_message, %{type: type}) when type in ["timeline", "community"], do: true
  defp social_message?(_message, _conversation), do: false

  defp subscribed_user_ids(%Message{sender_id: sender_id}) when is_integer(sender_id) do
    AccountSubscription
    |> where([s], s.subscribed_user_id == ^sender_id)
    |> where([s], s.user_id != ^sender_id)
    |> select([s], s.user_id)
    |> Repo.all()
  end

  defp subscribed_user_ids(%Message{remote_actor_id: remote_actor_id})
       when is_integer(remote_actor_id) do
    AccountSubscription
    |> where([s], s.remote_actor_id == ^remote_actor_id)
    |> select([s], s.user_id)
    |> Repo.all()
  end

  defp subscribed_user_ids(_message), do: []

  defp create_status_notification(user_id, %Message{} = message) when is_integer(user_id) do
    actor = message.sender || message.remote_actor

    attrs =
      %{
        user_id: user_id,
        type: "status",
        title: status_notification_title(actor),
        body: status_notification_body(message),
        url: Elektrine.Paths.post_path(message),
        source_type: "message",
        source_id: message.id,
        priority: "normal"
      }
      |> maybe_put_actor_id(message)
      |> maybe_put_remote_actor_id(message)

    Notifications.create_notification(attrs)
  end

  defp maybe_put_actor_id(attrs, %Message{sender_id: sender_id}) when is_integer(sender_id) do
    Map.put(attrs, :actor_id, sender_id)
  end

  defp maybe_put_actor_id(attrs, _message), do: attrs

  defp maybe_put_remote_actor_id(attrs, %Message{remote_actor_id: remote_actor_id})
       when is_integer(remote_actor_id) do
    Map.put(attrs, :metadata, %{remote_actor_id: remote_actor_id})
  end

  defp maybe_put_remote_actor_id(attrs, _message), do: attrs

  defp status_notification_title(%User{} = user), do: "#{display_name(user)} posted"
  defp status_notification_title(%Actor{} = actor), do: "#{display_name(actor)} posted"
  defp status_notification_title(_actor), do: "New post"

  defp display_name(%User{} = user), do: user.display_name || user.handle || user.username

  defp display_name(%Actor{} = actor),
    do: actor.display_name || actor.username || actor.domain || "Remote user"

  defp status_notification_body(%Message{content_warning: warning})
       when is_binary(warning) and warning != "" do
    warning
  end

  defp status_notification_body(%Message{title: title}) when is_binary(title) and title != "" do
    title
  end

  defp status_notification_body(%Message{content: content}) when is_binary(content) do
    content
    |> String.replace(~r/<[^>]*>/, "")
    |> String.slice(0, 140)
  end

  defp status_notification_body(_message), do: "Open Elektrine to view the post."
end
