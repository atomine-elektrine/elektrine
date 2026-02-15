defmodule ElektrineWeb.API.MailboxController do
  @moduledoc """
  API controller for mailbox information.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Email.{Mailboxes, Messages, Aliases}

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/mailbox
  Returns information about the current user's mailbox.
  """
  def show(conn, _params) do
    user = conn.assigns[:current_user]
    mailbox = Mailboxes.get_user_mailbox(user.id)

    if mailbox do
      conn
      |> put_status(:ok)
      |> json(%{mailbox: format_mailbox(mailbox)})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  @doc """
  GET /api/mailbox/stats
  Returns statistics for the current user's mailbox.
  """
  def stats(conn, _params) do
    user = conn.assigns[:current_user]
    mailbox = Mailboxes.get_user_mailbox(user.id)

    if mailbox do
      # Get unread counts for all categories
      unread_counts = Messages.get_all_unread_counts(mailbox.id)

      # Get total message counts
      total_counts = get_total_counts(mailbox.id)

      # Get alias count
      alias_count = length(Aliases.list_aliases(user.id))

      conn
      |> put_status(:ok)
      |> json(%{
        stats: %{
          unread: unread_counts,
          total: total_counts,
          aliases: alias_count
        }
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Mailbox not found"})
    end
  end

  # Private helpers

  defp format_mailbox(mailbox) do
    %{
      id: mailbox.id,
      email: mailbox.email,
      username: mailbox.username,
      forward_enabled: mailbox.forward_enabled,
      forward_to: if(mailbox.forward_enabled, do: mailbox.forward_to, else: nil),
      inserted_at: mailbox.inserted_at,
      updated_at: mailbox.updated_at
    }
  end

  defp get_total_counts(mailbox_id) do
    import Ecto.Query

    # Get counts by category
    counts =
      Elektrine.Email.Message
      |> where(mailbox_id: ^mailbox_id)
      |> where([m], is_nil(m.deleted) or m.deleted == false)
      |> where([m], is_nil(m.spam) or m.spam == false)
      |> group_by([m], m.category)
      |> select([m], {m.category, count(m.id)})
      |> Elektrine.Repo.all()
      |> Map.new()

    # Get sent count
    sent_count =
      Elektrine.Email.Message
      |> where(mailbox_id: ^mailbox_id)
      |> where([m], m.status == "sent")
      |> where([m], is_nil(m.deleted) or m.deleted == false)
      |> select([m], count(m.id))
      |> Elektrine.Repo.one() || 0

    # Get spam count
    spam_count =
      Elektrine.Email.Message
      |> where(mailbox_id: ^mailbox_id)
      |> where([m], m.spam == true)
      |> where([m], is_nil(m.deleted) or m.deleted == false)
      |> select([m], count(m.id))
      |> Elektrine.Repo.one() || 0

    # Get trash count
    trash_count =
      Elektrine.Email.Message
      |> where(mailbox_id: ^mailbox_id)
      |> where([m], m.deleted == true)
      |> select([m], count(m.id))
      |> Elektrine.Repo.one() || 0

    %{
      inbox: Map.get(counts, "inbox", 0) + Map.get(counts, nil, 0),
      feed: Map.get(counts, "feed", 0),
      ledger: Map.get(counts, "ledger", 0),
      stack: Map.get(counts, "stack", 0),
      reply_later: Map.get(counts, "reply_later", 0),
      sent: sent_count,
      spam: spam_count,
      trash: trash_count
    }
  end
end
