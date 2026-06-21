defmodule Elektrine.Repo.Migrations.BackfillOrphanedThreadMessages do
  use Ecto.Migration

  @moduledoc """
  Links messages that were left without a thread (thread_id IS NULL) into the
  thread of any later message in the same mailbox that references their Message-ID
  via In-Reply-To or References.

  This recovers conversation starters that were orphaned before Message-ID
  reconciliation landed for internal delivery: the reply existed and was threaded,
  but the starter never got attached because the linking header pointed at it.

  Header-based only (no subject-hash matching), so it never merges unrelated
  conversations that merely share a title. `translate(.., '<>', '')` strips any
  legacy angle brackets so normalized and bracketed Message-IDs compare equal.
  """

  def up do
    execute("""
    UPDATE email_messages AS o
    SET thread_id = sub.thread_id
    FROM (
      SELECT DISTINCT ON (oo.id) oo.id AS orphan_id, cc.thread_id AS thread_id
      FROM email_messages AS oo
      JOIN email_messages AS cc
        ON cc.mailbox_id = oo.mailbox_id
       AND cc.id <> oo.id
       AND cc.thread_id IS NOT NULL
       AND (
            translate(cc.in_reply_to, '<>', '') = translate(oo.message_id, '<>', '')
         OR translate(oo.message_id, '<>', '') = ANY(
              regexp_split_to_array(translate(COALESCE(cc."references", ''), '<>', ''), '\\s+')
            )
       )
      WHERE oo.thread_id IS NULL
        AND oo.message_id IS NOT NULL
        AND oo.message_id <> ''
      ORDER BY oo.id, cc.inserted_at, cc.id
    ) AS sub
    WHERE o.id = sub.orphan_id
    """)
  end

  def down do
    :ok
  end
end
