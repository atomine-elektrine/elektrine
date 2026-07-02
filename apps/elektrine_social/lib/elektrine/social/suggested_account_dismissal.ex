defmodule Elektrine.Social.SuggestedAccountDismissal do
  @moduledoc """
  Tracks accounts a user dismissed from follow suggestions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "suggested_account_dismissals" do
    field :dismissed_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :suggested_user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:user_id, :suggested_user_id, :dismissed_at])
    |> update_change(:dismissed_at, &Elektrine.Time.truncate/1)
    |> validate_required([:user_id, :suggested_user_id, :dismissed_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:suggested_user_id)
    |> unique_constraint([:user_id, :suggested_user_id],
      name: :suggested_account_dismissals_user_id_suggested_user_id_index
    )
  end
end
