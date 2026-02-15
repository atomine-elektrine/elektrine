defmodule Elektrine.Repo.Migrations.AddFriendRequestsTable do
  use Ecto.Migration

  def change do
    create table(:friend_requests) do
      add :requester_id, references(:users, on_delete: :delete_all), null: false
      add :recipient_id, references(:users, on_delete: :delete_all), null: false
      # "pending", "accepted", "rejected"
      add :status, :string, null: false, default: "pending"
      # Optional message with friend request
      add :message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:friend_requests, [:requester_id])
    create index(:friend_requests, [:recipient_id])
    create index(:friend_requests, [:status])
    create unique_index(:friend_requests, [:requester_id, :recipient_id])
  end
end
