defmodule Elektrine.Calendar.Calendar do
  @moduledoc """
  Schema for user calendars.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "calendars" do
    field :name, :string
    field :color, :string, default: "#3b82f6"
    field :description, :string
    field :timezone, :string, default: "UTC"
    field :is_default, :boolean, default: false
    field :ctag, :string
    field :order, :integer, default: 0

    belongs_to :user, Elektrine.Accounts.User
    has_many :events, Elektrine.Calendar.Event

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating a calendar.
  """
  def changeset(calendar, attrs) do
    calendar
    |> cast(attrs, [:name, :color, :description, :timezone, :is_default, :order, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, max: 255)
    |> validate_length(:color, max: 20)
    |> validate_length(:description, max: 1000)
    |> unique_constraint([:user_id, :name])
    |> generate_ctag()
  end

  defp generate_ctag(changeset) do
    if changeset.valid? && changeset.changes != %{} do
      ctag = "ctag-#{DateTime.utc_now() |> DateTime.to_unix()}"
      put_change(changeset, :ctag, ctag)
    else
      changeset
    end
  end
end
