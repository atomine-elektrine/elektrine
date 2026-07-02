defmodule Elektrine.Markers.Marker do
  @moduledoc """
  Persistent Mastodon/Pleroma-compatible read marker for a user timeline.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @timeline_format ~r/\A[a-zA-Z0-9_.:-]{1,64}\z/

  schema "api_markers" do
    field :timeline, :string
    field :last_read_id, :string
    field :version, :integer, default: 0
    field :unread_count, :integer, virtual: true, default: 0

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [:user_id, :timeline, :last_read_id, :version])
    |> update_change(:timeline, &String.trim/1)
    |> update_change(:last_read_id, &String.trim/1)
    |> validate_required([:user_id, :timeline, :last_read_id])
    |> validate_format(:timeline, @timeline_format)
    |> validate_length(:last_read_id, min: 1, max: 255)
    |> validate_number(:version, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :timeline])
  end
end
