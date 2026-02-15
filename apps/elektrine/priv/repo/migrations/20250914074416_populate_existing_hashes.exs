defmodule Elektrine.Repo.Migrations.PopulateExistingHashes do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Populate conversation hashes
    conversations =
      from(c in "conversations", where: is_nil(c.hash), select: c.id) |> repo().all()

    for id <- conversations do
      hash = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      repo().update_all(from(c in "conversations", where: c.id == ^id), set: [hash: hash])
    end

    # Populate email message hashes
    messages = from(m in "email_messages", where: is_nil(m.hash), select: m.id) |> repo().all()

    for id <- messages do
      hash = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      repo().update_all(from(m in "email_messages", where: m.id == ^id), set: [hash: hash])
    end
  end

  def down do
    repo().update_all("conversations", set: [hash: nil])
    repo().update_all("email_messages", set: [hash: nil])
  end
end
