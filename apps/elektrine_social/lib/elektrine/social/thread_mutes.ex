defmodule Elektrine.Social.ThreadMutes do
  @moduledoc """
  Persistent per-user mutes for social/AP threads.
  """

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.{Message, ThreadMute}

  def mute_thread(user_id, %Message{} = message) when is_integer(user_id) do
    %ThreadMute{}
    |> ThreadMute.changeset(%{
      user_id: user_id,
      message_id: message.id,
      thread_key: thread_key(message)
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def unmute_thread(user_id, %Message{} = message) when is_integer(user_id) do
    from(m in ThreadMute,
      where: m.user_id == ^user_id and m.thread_key == ^thread_key(message)
    )
    |> Repo.delete_all()
  end

  def muted?(user_id, %Message{} = message) when is_integer(user_id) do
    key = thread_key(message)

    Repo.exists?(
      from m in ThreadMute,
        where: m.user_id == ^user_id and m.thread_key == ^key
    )
  end

  def muted?(_user_id, _message), do: false

  def thread_key(%Message{} = message) do
    metadata = message.media_metadata || %{}

    cond do
      is_binary(metadata["context"]) and metadata["context"] != "" ->
        "ap:" <> metadata["context"]

      is_binary(metadata[:context]) and metadata[:context] != "" ->
        "ap:" <> metadata[:context]

      is_binary(metadata["inReplyTo"]) and metadata["inReplyTo"] != "" ->
        "ap:" <> metadata["inReplyTo"]

      is_binary(metadata[:inReplyTo]) and metadata[:inReplyTo] != "" ->
        "ap:" <> metadata[:inReplyTo]

      is_integer(message.reply_to_id) ->
        "message:" <> Integer.to_string(message.reply_to_id)

      true ->
        "message:" <> Integer.to_string(message.id)
    end
  end
end
