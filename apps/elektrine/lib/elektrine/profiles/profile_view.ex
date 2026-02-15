defmodule Elektrine.Profiles.ProfileView do
  @moduledoc """
  Schema for tracking profile page views and visitor analytics.
  Records both authenticated users and anonymous sessions with IP, user agent, and referrer information.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "profile_views" do
    field :viewer_session_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :referer, :string

    belongs_to :profile_user, Elektrine.Accounts.User
    belongs_to :viewer_user, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(profile_view, attrs) do
    profile_view
    |> cast(attrs, [
      :profile_user_id,
      :viewer_user_id,
      :viewer_session_id,
      :ip_address,
      :user_agent,
      :referer
    ])
    |> validate_required([:profile_user_id])
    |> validate_at_least_one_viewer_identifier()
    |> foreign_key_constraint(:profile_user_id)
    |> foreign_key_constraint(:viewer_user_id)
  end

  defp validate_at_least_one_viewer_identifier(changeset) do
    viewer_user_id = get_field(changeset, :viewer_user_id)
    viewer_session_id = get_field(changeset, :viewer_session_id)

    if is_nil(viewer_user_id) && is_nil(viewer_session_id) do
      add_error(
        changeset,
        :viewer_session_id,
        "must have either viewer_user_id or viewer_session_id"
      )
    else
      changeset
    end
  end
end
