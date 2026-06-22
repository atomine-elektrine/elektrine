defmodule Elektrine.Messaging.LinkPreviewBroadcast do
  @moduledoc """
  Shared helpers for polling a pending link preview and broadcasting the
  updated message to a conversation's PubSub topic.

  Extracted from `Elektrine.Messaging.ChatMessages` and
  `Elektrine.Social.Messages`, which had near-identical private helpers. The
  per-context differences (preload list, post-preload transform, and the
  PubSub topic) are passed in as options so the broadcast payloads and topics
  remain byte-identical to the originals.
  """

  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview

  @doc """
  Polls for a pending preview and broadcasts the update once it succeeds.

  `opts` are forwarded to `broadcast_update/2`.
  """
  def poll_and_broadcast(_message, _preview_id, 0, _opts), do: :ok

  def poll_and_broadcast(message, preview_id, attempts_left, opts) do
    :timer.sleep(1000)

    case Repo.get(LinkPreview, preview_id) do
      %{status: "success"} = preview ->
        broadcast_update(message, preview, opts)

        :ok

      %{status: "pending"} ->
        poll_and_broadcast(message, preview_id, attempts_left - 1, opts)

      _ ->
        :ok
    end
  end

  @doc """
  Attaches the resolved preview to the message, applies the per-context
  preloads/transform, and broadcasts `{:message_link_preview_updated, message}`
  on the given topic.

  ## Options

    * `:preload` - preload list passed to `Repo.preload/3` (default `[]`)
    * `:transform` - 1-arity function applied after preloading (default identity)
    * `:topic` - 1-arity function mapping the message to its PubSub topic
  """
  def broadcast_update(message, preview, opts) do
    preload = Keyword.get(opts, :preload, [])
    transform = Keyword.get(opts, :transform, & &1)
    topic_fun = Keyword.fetch!(opts, :topic)

    updated_message =
      %{message | link_preview: preview}
      |> Repo.preload(preload, force: true)
      |> transform.()

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      topic_fun.(message),
      {:message_link_preview_updated, updated_message}
    )
  end
end
