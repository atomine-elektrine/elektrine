defmodule Elektrine.Calendar.Event do
  @moduledoc """
  Schema for calendar events.
  Supports iCalendar/CalDAV properties.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Calendar.ICalendar

  schema "calendar_events" do
    field :uid, :string
    field :etag, :string
    field :summary, :string
    field :description, :string
    field :location, :string
    field :url, :string

    # Time fields
    field :dtstart, :utc_datetime
    field :dtend, :utc_datetime
    field :duration, :string
    field :all_day, :boolean, default: false
    field :timezone, :string

    # Recurrence
    field :rrule, :string
    field :rdate, {:array, :utc_datetime}, default: []
    field :exdate, {:array, :utc_datetime}, default: []
    field :recurrence_id, :utc_datetime

    # Status and classification
    field :status, :string, default: "CONFIRMED"
    field :transparency, :string, default: "OPAQUE"
    field :classification, :string, default: "PUBLIC"
    field :priority, :integer, default: 0

    # JSON fields
    field :alarms, {:array, :map}, default: []
    field :attendees, {:array, :map}, default: []
    field :organizer, :map

    # Categories/tags
    field :categories, {:array, :string}, default: []

    # Raw iCalendar data
    field :icalendar_data, :string

    # Sequence for updates
    field :sequence, :integer, default: 0

    belongs_to :calendar, Elektrine.Calendar.Calendar

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating an event.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :calendar_id,
      :uid,
      :summary,
      :description,
      :location,
      :url,
      :dtstart,
      :dtend,
      :duration,
      :all_day,
      :timezone,
      :rrule,
      :rdate,
      :exdate,
      :recurrence_id,
      :status,
      :transparency,
      :classification,
      :priority,
      :alarms,
      :attendees,
      :organizer,
      :categories,
      :icalendar_data,
      :sequence
    ])
    |> validate_required([:calendar_id, :dtstart])
    |> ensure_uid()
    |> generate_etag()
    |> increment_sequence()
    |> unique_constraint([:calendar_id, :uid])
  end

  @doc """
  Changeset for CalDAV PUT requests with raw iCalendar data.
  """
  def caldav_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :calendar_id,
      :uid,
      :summary,
      :description,
      :location,
      :url,
      :dtstart,
      :dtend,
      :duration,
      :all_day,
      :timezone,
      :rrule,
      :rdate,
      :exdate,
      :recurrence_id,
      :status,
      :transparency,
      :classification,
      :priority,
      :alarms,
      :attendees,
      :organizer,
      :categories,
      :icalendar_data,
      :sequence,
      :etag
    ])
    |> validate_required([:calendar_id, :uid, :dtstart])
    |> generate_etag()
    |> unique_constraint([:calendar_id, :uid])
  end

  defp ensure_uid(changeset) do
    case get_field(changeset, :uid) do
      nil -> put_change(changeset, :uid, ICalendar.generate_uid())
      _ -> changeset
    end
  end

  defp generate_etag(changeset) do
    if changeset.valid? && changeset.changes != %{} do
      etag = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      put_change(changeset, :etag, etag)
    else
      changeset
    end
  end

  defp increment_sequence(changeset) do
    if get_change(changeset, :uid) == nil && changeset.data.id do
      # Updating existing event - increment sequence
      current = get_field(changeset, :sequence) || 0
      put_change(changeset, :sequence, current + 1)
    else
      changeset
    end
  end
end
