defmodule Elektrine.Admin.AnnouncementDismissal do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "announcement_dismissals" do
    field :dismissed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :announcement, Elektrine.Admin.Announcement

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for dismissing an announcement.
  """
  def changeset(announcement_dismissal, attrs) do
    announcement_dismissal
    |> cast(attrs, [:dismissed_at, :user_id, :announcement_id])
    |> validate_required([:dismissed_at, :user_id, :announcement_id])
    |> unique_constraint([:user_id, :announcement_id],
      message: "You have already dismissed this announcement"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:announcement_id)
  end
end
