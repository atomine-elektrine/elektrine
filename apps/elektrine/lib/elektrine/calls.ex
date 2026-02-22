defmodule Elektrine.Calls do
  @moduledoc """
  The Calls context for managing audio and video calls.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Calls.Call
  alias Elektrine.Repo

  @doc """
  Initiates a new call between two users.
  """
  def initiate_call(caller_id, callee_id, call_type, conversation_id \\ nil) do
    # Privacy: Check if call is allowed
    case Elektrine.Privacy.can_call?(caller_id, callee_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, :allowed} ->
        # Auto-cleanup stale calls (> 2 minutes old)
        two_minutes_ago = DateTime.utc_now() |> DateTime.add(-120, :second)

        if existing_caller = get_active_call(caller_id) do
          if DateTime.compare(existing_caller.inserted_at, two_minutes_ago) == :lt do
            require Logger

            Logger.warning(
              "Force ending stale call #{existing_caller.id} for caller #{caller_id}"
            )

            end_call(existing_caller.id)
          end
        end

        if existing_callee = get_active_call(callee_id) do
          if DateTime.compare(existing_callee.inserted_at, two_minutes_ago) == :lt do
            require Logger

            Logger.warning(
              "Force ending stale call #{existing_callee.id} for callee #{callee_id}"
            )

            end_call(existing_callee.id)
          end
        end

        # Now check for active calls after cleanup
        cond do
          get_active_call(caller_id) ->
            {:error, :caller_already_in_call}

          get_active_call(callee_id) ->
            {:error, :callee_already_in_call}

          too_many_recent_calls?(caller_id) ->
            {:error, :rate_limit_exceeded}

          true ->
            %Call{}
            |> Call.changeset(%{
              caller_id: caller_id,
              callee_id: callee_id,
              call_type: call_type,
              conversation_id: conversation_id,
              status: "initiated"
            })
            |> Repo.insert()
        end
    end
  end

  @doc """
  Check if user has too many recent call attempts (rate limiting).
  Max 5 calls per minute to prevent spam/DoS.
  """
  def too_many_recent_calls?(user_id) do
    one_minute_ago = DateTime.utc_now() |> DateTime.add(-60, :second)

    recent_call_count =
      Call
      |> where([c], c.caller_id == ^user_id)
      |> where([c], c.inserted_at > ^one_minute_ago)
      |> select([c], count(c.id))
      |> Repo.one()

    recent_call_count >= 5
  end

  @doc """
  Updates call status.
  """
  def update_call_status(call_id, status, attrs \\ %{}) do
    call = Repo.get!(Call, call_id) |> Repo.preload([:caller, :callee, :conversation])

    # Don't update if status hasn't changed
    if call.status == status do
      {:ok, call}
    else
      attrs = Map.put(attrs, :status, status)

      # Auto-set started_at when call becomes active
      attrs =
        if status == "active" and is_nil(call.started_at) do
          Map.put(attrs, :started_at, DateTime.utc_now())
        else
          attrs
        end

      # Auto-set ended_at and calculate duration when call ends
      attrs =
        if status in ["ended", "rejected", "missed", "failed"] and is_nil(call.ended_at) do
          ended_at = DateTime.utc_now()

          duration =
            if call.started_at do
              DateTime.diff(ended_at, call.started_at)
            else
              0
            end

          attrs
          |> Map.put(:ended_at, ended_at)
          |> Map.put(:duration_seconds, duration)
        else
          attrs
        end

      result =
        call
        |> Call.changeset(attrs)
        |> Repo.update()

      # Create system message in conversation when call ends
      case result do
        {:ok, updated_call} when status in ["ended", "rejected", "missed", "failed"] ->
          if updated_call.conversation_id do
            create_call_log_message(updated_call)
          end

          result

        _ ->
          result
      end
    end
  end

  # Create a system message in the conversation for call log
  defp create_call_log_message(call) do
    require Logger

    message_content = format_call_log_message(call)

    # Create system message - use a system user ID (admin or create a dedicated system user)
    # Use the caller as sender because system messages require sender_id.
    sender_id = call.caller_id

    %Elektrine.Messaging.Message{}
    |> Elektrine.Messaging.Message.changeset(%{
      conversation_id: call.conversation_id,
      sender_id: sender_id,
      content: message_content,
      message_type: "system",
      visibility: "conversation",
      post_type: "message",
      media_metadata: %{
        call_id: call.id,
        call_type: call.call_type,
        call_status: call.status,
        call_duration: call.duration_seconds
      }
    })
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        # Update conversation's last message time
        import Ecto.Query

        from(c in Elektrine.Messaging.Conversation, where: c.id == ^call.conversation_id)
        |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])

        # Broadcast to conversation
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{call.conversation_id}",
          {:new_message, message}
        )

        {:ok, message}

      error ->
        Logger.error("Failed to create call log message: #{inspect(error)}")
        error
    end
  end

  defp format_call_log_message(call) do
    call_type = if call.call_type == "video", do: "Video call", else: "Audio call"

    case call.status do
      "ended" ->
        if call.duration_seconds && call.duration_seconds > 0 do
          "#{call_type} ended - Duration: #{format_duration(call.duration_seconds)}"
        else
          "#{call_type} ended"
        end

      "rejected" ->
        "#{call_type} declined"

      "missed" ->
        "Missed #{String.downcase(call_type)}"

      "failed" ->
        "#{call_type} failed to connect"

      _ ->
        "#{call_type} #{call.status}"
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}:#{pad(minutes)}:#{pad(secs)}"
      minutes > 0 -> "#{minutes}:#{pad(secs)}"
      true -> "#{secs}s"
    end
  end

  defp pad(num), do: String.pad_leading("#{num}", 2, "0")

  @doc """
  Gets a call by ID.
  """
  def get_call(id), do: Repo.get(Call, id)

  @doc """
  Gets call with preloaded caller and callee.
  """
  def get_call_with_users(id) do
    Call
    |> where([c], c.id == ^id)
    |> preload([:caller, :callee])
    |> Repo.one()
  end

  @doc """
  Lists all calls for a user (as caller or callee).
  """
  def list_user_calls(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Call
    |> where([c], c.caller_id == ^user_id or c.callee_id == ^user_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(^limit)
    |> preload([:caller, :callee])
    |> Repo.all()
  end

  @doc """
  Lists calls for a specific conversation.
  """
  def list_conversation_calls(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Call
    |> where([c], c.conversation_id == ^conversation_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(^limit)
    |> preload([:caller, :callee])
    |> Repo.all()
  end

  @doc """
  Finds an active call for a user.
  Returns the most recent active call if multiple exist.
  """
  def get_active_call(user_id) do
    Call
    |> where([c], c.status in ["initiated", "ringing", "active"])
    |> where([c], c.caller_id == ^user_id or c.callee_id == ^user_id)
    |> order_by([c], desc: c.inserted_at)
    |> limit(1)
    |> preload([:caller, :callee])
    |> Repo.one()
  end

  @doc """
  Ends a call.
  """
  def end_call(call_id) do
    update_call_status(call_id, "ended")
  end

  @doc """
  Answers an incoming call.
  """
  def answer_call(call_id) do
    update_call_status(call_id, "active")
  end

  @doc """
  Rejects a call.
  """
  def reject_call(call_id) do
    update_call_status(call_id, "rejected")
  end

  @doc """
  Marks a call as missed.
  """
  def miss_call(call_id) do
    update_call_status(call_id, "missed")
  end
end
