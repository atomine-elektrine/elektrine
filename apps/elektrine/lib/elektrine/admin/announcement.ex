defmodule Elektrine.Admin.Announcement do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Announcement types
  @types ["info", "warning", "maintenance", "feature", "urgent"]

  schema "announcements" do
    field :active, :boolean, default: true
    field :type, :string, default: "info"
    field :title, :string
    field :content, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    belongs_to :created_by, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid announcement types.
  """
  def types, do: @types

  @doc """
  Creates a changeset for announcements.
  """
  def changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [:title, :content, :type, :starts_at, :ends_at, :active, :created_by_id])
    |> validate_required([:title, :content, :type, :created_by_id])
    |> validate_inclusion(:type, @types, message: "must be one of: #{Enum.join(@types, ", ")}")
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:content, min: 1, max: 2000)
    |> validate_dates()
    |> foreign_key_constraint(:created_by_id)
  end

  @doc """
  Checks if an announcement is currently active and within its time window.
  """
  def currently_active?(%__MODULE__{} = announcement) do
    now = DateTime.utc_now()

    announcement.active &&
      (is_nil(announcement.starts_at) || DateTime.compare(announcement.starts_at, now) != :gt) &&
      (is_nil(announcement.ends_at) || DateTime.compare(announcement.ends_at, now) != :lt)
  end

  @doc """
  Returns CSS classes for the announcement type.
  """
  def type_classes("info"), do: "bg-blue-50 border-blue-200 text-blue-800"
  def type_classes("warning"), do: "bg-yellow-50 border-yellow-200 text-yellow-800"
  def type_classes("maintenance"), do: "bg-gray-50 border-gray-200 text-gray-800"
  def type_classes("feature"), do: "bg-green-50 border-green-200 text-green-800"
  def type_classes("urgent"), do: "bg-red-50 border-red-200 text-red-800"
  def type_classes(_), do: "bg-blue-50 border-blue-200 text-blue-800"

  @doc """
  Returns icon name for the announcement type.
  """
  def type_icon("info"), do: "information-circle"
  def type_icon("warning"), do: "exclamation-triangle"
  def type_icon("maintenance"), do: "cog"
  def type_icon("feature"), do: "sparkles"
  def type_icon("urgent"), do: "exclamation-circle"
  def type_icon(_), do: "information-circle"

  # Private helper functions

  defp validate_dates(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    cond do
      is_nil(starts_at) && is_nil(ends_at) ->
        changeset

      is_nil(starts_at) || is_nil(ends_at) ->
        changeset

      DateTime.compare(starts_at, ends_at) != :lt ->
        add_error(changeset, :ends_at, "must be after start date")

      true ->
        changeset
    end
  end
end
