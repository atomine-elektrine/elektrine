defmodule Elektrine.Profiles.SitePageVisit do
  @moduledoc """
  Schema for site-wide HTML page visits across public app and profile routes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "site_page_visits" do
    field :visitor_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :referer, :string
    field :request_host, :string
    field :request_path, :string
    field :status, :integer

    belongs_to :viewer_user, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(site_page_visit, attrs) do
    site_page_visit
    |> cast(attrs, [
      :viewer_user_id,
      :visitor_id,
      :ip_address,
      :user_agent,
      :referer,
      :request_host,
      :request_path,
      :status
    ])
    |> validate_required([:request_host, :request_path, :status])
    |> validate_number(:status, greater_than_or_equal_to: 100, less_than: 600)
    |> validate_at_least_one_visitor_identifier()
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
