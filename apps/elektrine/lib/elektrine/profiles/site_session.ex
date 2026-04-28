defmodule Elektrine.Profiles.SiteSession do
  @moduledoc """
  Rollup schema for site-wide visitor sessions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "site_sessions" do
    field :session_id, :string
    field :visitor_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :referer, :string
    field :entry_host, :string
    field :entry_path, :string
    field :exit_host, :string
    field :exit_path, :string
    field :page_views, :integer, default: 0
    field :started_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :duration_seconds, :integer, default: 0

    belongs_to :viewer_user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(site_session, attrs) do
    site_session
    |> cast(attrs, [
      :session_id,
      :viewer_user_id,
      :visitor_id,
      :ip_address,
      :user_agent,
      :referer,
      :entry_host,
      :entry_path,
      :exit_host,
      :exit_path,
      :page_views,
      :started_at,
      :last_seen_at,
      :duration_seconds
    ])
    |> validate_required([
      :session_id,
      :entry_host,
      :entry_path,
      :exit_host,
      :exit_path,
      :page_views,
      :started_at,
      :last_seen_at,
      :duration_seconds
    ])
    |> validate_number(:page_views, greater_than: 0)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
    |> validate_at_least_one_visitor_identifier()
    |> unique_constraint(:session_id)
    |> foreign_key_constraint(:viewer_user_id)
  end

  defp validate_at_least_one_visitor_identifier(changeset) do
    viewer_user_id = get_field(changeset, :viewer_user_id)
    visitor_id = get_field(changeset, :visitor_id)
    ip_address = get_field(changeset, :ip_address)

    if is_nil(viewer_user_id) && blank?(visitor_id) && blank?(ip_address) do
      add_error(
        changeset,
        :visitor_id,
        "must have either viewer_user_id, visitor_id, or ip_address"
      )
    else
      changeset
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
