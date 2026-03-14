defmodule ElektrineWeb.Plugs.LoadConflicts do
  @moduledoc false
  import Plug.Conn
  import Ecto.Query
  alias Elektrine.Accounts.User
  alias Elektrine.Email.{Alias, Mailbox}
  alias Elektrine.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only load conflicts for admin routes
    if String.starts_with?(conn.request_path, "/pripyat") do
      conflicts = get_conflict_counts()
      assign(conn, :system_conflicts, conflicts)
    else
      conn
    end
  end

  defp get_conflict_counts do
    # Quick check for any conflicts
    has_username_conflicts =
      Repo.exists?(
        from u in User,
          where:
            fragment(
              """
                EXISTS (
                  SELECT 1 FROM users u2
                  WHERE lower(u2.username) = lower(?)
                  AND u2.id != ?
                )
              """,
              u.username,
              u.id
            ),
          limit: 1
      )

    has_mailbox_conflicts =
      Repo.exists?(
        from m in Mailbox,
          where:
            fragment(
              """
                EXISTS (
                  SELECT 1 FROM mailboxes m2
                  WHERE lower(m2.email) = lower(?)
                  AND m2.id != ?
                )
              """,
              m.email,
              m.id
            ),
          limit: 1
      )

    has_alias_conflicts =
      Repo.exists?(
        from a in Alias,
          where:
            fragment(
              """
                EXISTS (
                  SELECT 1 FROM email_aliases a2
                  WHERE lower(a2.alias_email) = lower(?)
                  AND a2.id != ?
                )
              """,
              a.alias_email,
              a.id
            ),
          limit: 1
      )

    %{
      has_any: has_username_conflicts || has_mailbox_conflicts || has_alias_conflicts,
      has_username_conflicts: has_username_conflicts,
      has_mailbox_conflicts: has_mailbox_conflicts,
      has_alias_conflicts: has_alias_conflicts
    }
  end
end
