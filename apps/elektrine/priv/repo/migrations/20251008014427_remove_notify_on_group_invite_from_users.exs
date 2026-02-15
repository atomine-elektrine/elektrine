defmodule Elektrine.Repo.Migrations.RemoveNotifyOnGroupInviteFromUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :notify_on_group_invite
    end
  end
end
