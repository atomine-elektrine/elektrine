defmodule Elektrine.Developer.DataExport do
  @moduledoc """
  Schema for data export jobs.

  Tracks the status of data export requests for various data types.
  Exports are processed asynchronously and available for download for 7 days.

  ## Export Types

  - `email` - Email messages and metadata
  - `social` - Timeline posts, likes, followers, following
  - `chat` - Conversations and messages
  - `contacts` - Addressbook contacts
  - `calendar` - Calendar events
  - `account` - Profile, settings, preferences
  - `full` - Everything (GDPR compliance export)

  ## Formats

  - `json` - JSON format (default, most developer-friendly)
  - `csv` - CSV format (for spreadsheet import)
  - `mbox` - Mbox format (email only)
  - `vcf` - vCard format (contacts only)
  - `ical` - iCal format (calendar only)
  - `zip` - ZIP archive (for full exports)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(email social chat contacts calendar account full)
  @valid_formats ~w(json csv mbox vcf ical zip)
  @valid_statuses ~w(pending processing completed failed expired)

  # Export files are available for 7 days
  @default_expiry_days 7

  schema "data_exports" do
    field :export_type, :string
    field :format, :string, default: "json"
    field :status, :string, default: "pending"
    field :file_path, :string
    field :file_size, :integer
    field :item_count, :integer
    field :filters, :map, default: %{}
    field :download_token, :string
    field :download_count, :integer, default: 0
    field :expires_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Returns valid export types.
  """
  def valid_types, do: @valid_types

  @doc """
  Returns valid formats.
  """
  def valid_formats, do: @valid_formats

  @doc """
  Returns valid statuses.
  """
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns formats available for each export type.
  """
  def formats_for_type("email"), do: ~w(json mbox zip)
  def formats_for_type("contacts"), do: ~w(json vcf csv)
  def formats_for_type("calendar"), do: ~w(json ical)
  def formats_for_type("full"), do: ~w(zip)
  def formats_for_type(_), do: ~w(json csv)

  @doc """
  Creates a changeset for a new export.
  """
  def changeset(export, attrs) do
    export
    |> cast(attrs, [:export_type, :format, :filters, :user_id])
    |> validate_required([:export_type, :user_id])
    |> validate_inclusion(:export_type, @valid_types)
    |> validate_inclusion(:format, @valid_formats)
    |> validate_format_for_type()
    |> generate_download_token()
    |> set_expiry()
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Marks an export as started.
  """
  def start_changeset(export) do
    export
    |> change()
    |> put_change(:status, "processing")
    |> put_change(:started_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Marks an export as completed.
  """
  def complete_changeset(export, file_path, file_size, item_count) do
    export
    |> change()
    |> put_change(:status, "completed")
    |> put_change(:file_path, file_path)
    |> put_change(:file_size, file_size)
    |> put_change(:item_count, item_count)
    |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Marks an export as failed.
  """
  def fail_changeset(export, error) do
    export
    |> change()
    |> put_change(:status, "failed")
    |> put_change(:error, error)
    |> put_change(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Increments the download count.
  """
  def download_changeset(export) do
    export
    |> change()
    |> put_change(:download_count, (export.download_count || 0) + 1)
  end

  @doc """
  Checks if an export has expired.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if an export is ready for download.
  """
  def downloadable?(%__MODULE__{status: "completed"} = export), do: not expired?(export)
  def downloadable?(_), do: false

  # Validate that the format is valid for the export type
  defp validate_format_for_type(changeset) do
    export_type = get_field(changeset, :export_type)
    format = get_field(changeset, :format) || "json"

    if export_type && format not in formats_for_type(export_type) do
      add_error(changeset, :format, "is not valid for #{export_type} exports")
    else
      changeset
    end
  end

  # Generate a secure download token
  defp generate_download_token(changeset) do
    if get_change(changeset, :download_token) do
      changeset
    else
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      put_change(changeset, :download_token, token)
    end
  end

  # Set default expiry
  defp set_expiry(changeset) do
    if get_change(changeset, :expires_at) do
      changeset
    else
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@default_expiry_days * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    end
  end
end
