defmodule Elektrine.Social.PostDismissal do
  @moduledoc """
  Tracks negative engagement signals - when users scroll past content quickly,
  explicitly hide posts, or mark them as "not interested".

  Used by the recommendation algorithm to penalize content users implicitly dislike.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @dismissal_types ~w(scrolled_past hidden not_interested)

  schema "post_dismissals" do
    # scrolled_past, hidden, not_interested
    field :dismissal_type, :string
    # how long before dismissing
    field :dwell_time_ms, :integer

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message

    timestamps(updated_at: false)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:user_id, :message_id, :dismissal_type, :dwell_time_ms])
    |> validate_required([:user_id, :message_id, :dismissal_type])
    |> validate_inclusion(:dismissal_type, @dismissal_types)
    |> unique_constraint([:user_id, :message_id, :dismissal_type],
      name: :post_dismissals_user_id_message_id_dismissal_type_index
    )
  end

  def dismissal_types, do: @dismissal_types
end
