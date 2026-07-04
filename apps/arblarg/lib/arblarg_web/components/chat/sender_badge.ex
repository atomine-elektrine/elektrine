defmodule ArblargWeb.Components.Chat.SenderBadge do
  @moduledoc """
  Small badge shown next to automated chat message authors.

  Webhook-authored messages hydrate a sender-shaped map with `webhook: true`
  (see `Elektrine.Messaging.ChatMessages`); bot user accounts carry an
  `is_bot` flag. Both render a small "APP"/"BOT" badge so automated authors
  are visually distinct from people.

  Usage in message templates, next to the sender name:

      <.sender_badge sender={message_sender(message)} />

  Renders nothing for regular human senders.
  """
  use Phoenix.Component

  attr :sender, :map, default: nil

  def sender_badge(assigns) do
    assigns = assign(assigns, :label, badge_label(assigns.sender))

    ~H"""
    <span
      :if={@label}
      class="badge badge-neutral badge-xs uppercase tracking-wide"
      title="Automated sender"
    >
      {@label}
    </span>
    """
  end

  @doc """
  Returns "APP" for webhook senders, "BOT" for bot users, nil otherwise.
  """
  def badge_label(sender) when is_map(sender) do
    cond do
      Map.get(sender, :webhook) == true -> "APP"
      Map.get(sender, :is_bot) == true -> "BOT"
      true -> nil
    end
  end

  def badge_label(_sender), do: nil
end
