defmodule Elektrine.Repo.Migrations.CreateCalendars do
  use Ecto.Migration

  def change do
    # User calendars
    create table(:calendars) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string, default: "#3b82f6"
      add :description, :text
      add :timezone, :string, default: "UTC"
      add :is_default, :boolean, default: false
      # Collection sync token for CalDAV
      add :ctag, :string
      add :order, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:calendars, [:user_id])
    create unique_index(:calendars, [:user_id, :name])

    # Calendar events
    create table(:calendar_events) do
      add :calendar_id, references(:calendars, on_delete: :delete_all), null: false
      # iCalendar UID
      add :uid, :string, null: false
      # Entity tag for sync
      add :etag, :string
      # Event title
      add :summary, :string
      add :description, :text
      add :location, :string
      add :url, :string

      # Time fields
      add :dtstart, :utc_datetime, null: false
      add :dtend, :utc_datetime
      # ISO 8601 duration
      add :duration, :string
      add :all_day, :boolean, default: false
      add :timezone, :string

      # Recurrence
      # RRULE string
      add :rrule, :string
      add :rdate, {:array, :utc_datetime}, default: []
      add :exdate, {:array, :utc_datetime}, default: []
      # For recurring event exceptions
      add :recurrence_id, :utc_datetime

      # Status and classification
      # TENTATIVE, CONFIRMED, CANCELLED
      add :status, :string, default: "CONFIRMED"
      # OPAQUE, TRANSPARENT
      add :transparency, :string, default: "OPAQUE"
      # PUBLIC, PRIVATE, CONFIDENTIAL
      add :classification, :string, default: "PUBLIC"
      add :priority, :integer, default: 0

      # Alarms stored as JSON array
      add :alarms, {:array, :map}, default: []

      # Attendees stored as JSON array
      add :attendees, {:array, :map}, default: []
      add :organizer, :map

      # Categories/tags
      add :categories, {:array, :string}, default: []

      # Raw iCalendar data for faithful round-trip
      add :icalendar_data, :text

      # Sequence for updates
      add :sequence, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:calendar_events, [:calendar_id])
    create unique_index(:calendar_events, [:calendar_id, :uid])
    create index(:calendar_events, [:dtstart])
    create index(:calendar_events, [:dtend])
    create index(:calendar_events, [:calendar_id, :dtstart, :dtend])
  end
end
