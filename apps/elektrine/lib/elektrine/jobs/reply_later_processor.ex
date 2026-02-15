defmodule Elektrine.Jobs.ReplyLaterProcessor do
  @moduledoc """
  Processes reply later (boomerang) messages and returns them to inbox when due.
  """

  require Logger
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.Message

  @doc """
  Processes all due reply later messages and returns them to inbox.
  """
  def run do
    now = DateTime.utc_now()

    # Find all messages where reply_later_at has passed
    due_messages =
      Message
      |> where([m], not is_nil(m.reply_later_at))
      |> where([m], m.reply_later_at <= ^now)
      |> where([m], not m.deleted)
      |> where([m], not m.archived)
      |> Repo.all()

    count = length(due_messages)

    if count > 0 do
      Logger.info("Processing #{count} reply later message(s)")

      # Clear reply_later_at for each message to return them to inbox
      Enum.each(due_messages, fn message ->
        case Elektrine.Email.clear_reply_later(message) do
          {:ok, _updated_message} ->
            :ok

          {:error, changeset} ->
            Logger.error(
              "Failed to clear reply_later for message #{message.id}: #{inspect(changeset.errors)}"
            )
        end
      end)

      Logger.info("Successfully processed #{count} reply later message(s)")
    end

    :ok
  end
end
