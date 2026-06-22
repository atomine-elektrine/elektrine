defmodule Elektrine.Uptime.Monitor do
  @moduledoc """
  User-owned uptime monitor describing a target to probe on an interval.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Security.URLValidator

  @type t :: %__MODULE__{}

  @check_types ~w(http tcp ping)
  @visibilities ~w(private public)
  @statuses ~w(up down)
  @min_interval_seconds 60

  schema "uptime_monitors" do
    field :name, :string
    field :check_type, :string
    field :target, :string
    field :port, :integer
    field :expected_status, :integer, default: 200
    field :keyword, :string
    field :interval_seconds, :integer, default: 300
    field :timeout_ms, :integer, default: 10_000
    field :enabled, :boolean, default: true
    field :last_status, :string
    field :last_checked_at, :utc_datetime
    field :consecutive_failures, :integer, default: 0
    field :failure_threshold, :integer, default: 2
    field :notify_email, :boolean, default: false
    field :notify_in_app, :boolean, default: true
    field :public_slug, :string
    field :visibility, :string, default: "private"

    belongs_to :user, Elektrine.Accounts.User
    has_many :checks, Elektrine.Uptime.Check, foreign_key: :monitor_id
    has_many :incidents, Elektrine.Uptime.Incident, foreign_key: :monitor_id

    timestamps(type: :utc_datetime)
  end

  @user_editable_fields [
    :name,
    :check_type,
    :target,
    :port,
    :expected_status,
    :keyword,
    :interval_seconds,
    :timeout_ms,
    :enabled,
    :failure_threshold,
    :notify_email,
    :notify_in_app,
    :visibility,
    :user_id
  ]

  def check_types, do: @check_types
  def visibilities, do: @visibilities
  def min_interval_seconds, do: @min_interval_seconds

  def changeset(monitor, attrs) do
    monitor
    |> cast(attrs, @user_editable_fields)
    |> update_change(:check_type, &normalize_downcase/1)
    |> update_change(:target, &normalize_target/1)
    |> update_change(:visibility, &normalize_downcase/1)
    |> validate_required([:name, :check_type, :target, :user_id])
    |> validate_inclusion(:check_type, @check_types)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:enabled, [true, false])
    |> validate_length(:name, max: 255)
    |> validate_number(:interval_seconds, greater_than_or_equal_to: @min_interval_seconds)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 120_000)
    |> validate_number(:failure_threshold,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_number(:expected_status,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 599
    )
    |> validate_check_type_specifics()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:public_slug, name: :uptime_monitors_public_slug_unique)
  end

  @doc false
  def update_check_state_changeset(monitor, attrs) do
    monitor
    |> cast(attrs, [:last_status, :last_checked_at, :consecutive_failures])
    |> validate_inclusion(:last_status, @statuses)
    |> validate_number(:consecutive_failures, greater_than_or_equal_to: 0)
  end

  # tcp requires a port; http validates the target via URLValidator;
  # tcp/ping reject private-IP literal targets.
  defp validate_check_type_specifics(changeset) do
    case get_field(changeset, :check_type) do
      "http" ->
        validate_http_target(changeset)

      "tcp" ->
        changeset
        |> validate_required([:port])
        |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
        |> validate_public_target()

      "ping" ->
        validate_public_target(changeset)

      _ ->
        changeset
    end
  end

  defp validate_http_target(changeset) do
    case get_field(changeset, :target) do
      target when is_binary(target) and target != "" ->
        case URLValidator.validate(target) do
          :ok ->
            changeset

          {:error, reason} ->
            add_error(changeset, :target, http_target_error(reason))
        end

      _ ->
        changeset
    end
  end

  defp validate_public_target(changeset) do
    case get_field(changeset, :target) do
      target when is_binary(target) and target != "" ->
        if URLValidator.private_ip?(target) do
          add_error(changeset, :target, "must be a public address")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp http_target_error(:missing_scheme), do: "must be a full http(s) URL"
  defp http_target_error(:invalid_scheme), do: "must use http or https"
  defp http_target_error(:dangerous_port), do: "uses a disallowed port"
  defp http_target_error(:private_ip), do: "must be a public address"
  defp http_target_error(_reason), do: "is not a valid public URL"

  defp normalize_downcase(nil), do: nil
  defp normalize_downcase(value), do: value |> String.trim() |> String.downcase()

  defp normalize_target(nil), do: nil
  defp normalize_target(value), do: String.trim(value)
end
