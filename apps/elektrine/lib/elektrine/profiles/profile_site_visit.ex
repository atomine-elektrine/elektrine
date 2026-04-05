defmodule Elektrine.Profiles.ProfileSiteVisit do
  @moduledoc """
  Schema for page-level visits to profile and custom-domain sites.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "profile_site_visits" do
    field :visitor_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :referer, :string
    field :request_host, :string
    field :request_path, :string

    belongs_to :profile_user, Elektrine.Accounts.User
    belongs_to :viewer_user, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(profile_site_visit, attrs) do
    profile_site_visit
    |> cast(attrs, [
      :profile_user_id,
      :viewer_user_id,
      :visitor_id,
      :ip_address,
      :user_agent,
      :referer,
      :request_host,
      :request_path
    ])
    |> validate_required([:profile_user_id, :request_host, :request_path])
    |> validate_at_least_one_visitor_identifier()
    |> foreign_key_constraint(:profile_user_id)
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
