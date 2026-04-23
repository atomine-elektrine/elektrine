defmodule Elektrine.Messaging.ModerationAction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.Utils, as: FederationUtils
  alias Elektrine.Repo

  schema "moderation_actions" do
    field :action_type, :string
    field :reason, :string
    field :duration, :integer
    field :details, :map

    belongs_to :target_user, Elektrine.Accounts.User
    belongs_to :moderator, Elektrine.Accounts.User
    belongs_to :conversation, Elektrine.Social.Conversation

    timestamps(type: :utc_datetime)
  end

  @valid_actions ~w(timeout kick delete_message ban warn)

  @doc false
  def changeset(moderation_action, attrs) do
    moderation_action
    |> cast(attrs, [
      :action_type,
      :target_user_id,
      :moderator_id,
      :conversation_id,
      :reason,
      :duration,
      :details
    ])
    |> validate_required([:action_type, :target_user_id, :moderator_id])
    |> validate_inclusion(:action_type, @valid_actions)
  end

  def log_action(action_type, target_user_id, moderator_id, opts \\ []) do
    attrs = %{
      action_type: action_type,
      target_user_id: target_user_id,
      moderator_id: moderator_id,
      conversation_id: Keyword.get(opts, :conversation_id),
      reason: Keyword.get(opts, :reason),
      duration: Keyword.get(opts, :duration),
      details: Keyword.get(opts, :details, %{})
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Elektrine.Repo.insert()
    |> case do
      {:ok, action} ->
        maybe_publish_federation_action(action, moderator_id, target_user_id)
        {:ok, action}

      error ->
        error
    end
  end

  defp maybe_publish_federation_action(
         %__MODULE__{conversation_id: conversation_id, action_type: action_type} = action,
         moderator_id,
         target_user_id
       )
       when is_integer(conversation_id) and is_integer(moderator_id) and
              is_integer(target_user_id) do
    with %User{} = target_user <- Repo.get(User, target_user_id),
         action_kind when is_binary(action_kind) <- action_kind(action_type) do
      payload = %{
        "action" => %{
          "id" => "moderation:#{action.id}",
          "kind" => action_kind,
          "target" => %{
            "type" => "member",
            "id" => FederationUtils.sender_payload(target_user)["uri"]
          },
          "occurred_at" => DateTime.to_iso8601(action.inserted_at || DateTime.utc_now()),
          "duration_seconds" => action.duration,
          "reason" => action.reason
        }
      }

      _ =
        Federation.publish_extension_event(
          conversation_id,
          moderator_id,
          "moderation.action.recorded",
          payload
        )
    end

    :ok
  end

  defp maybe_publish_federation_action(_action, _moderator_id, _target_user_id), do: :ok

  defp action_kind("timeout"), do: "timeout"
  defp action_kind("kick"), do: "kick"
  defp action_kind("delete_message"), do: "delete_message"
  defp action_kind("ban"), do: "ban"
  defp action_kind("warn"), do: "warn"
  defp action_kind(_action_type), do: nil
end
