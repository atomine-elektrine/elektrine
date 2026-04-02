defmodule Elektrine.Profiles.UserBadge do
  @moduledoc """
  Schema for user badges indicating roles, achievements, or special statuses.
  Supports verified, staff, admin, moderator, supporter, developer, and custom badge types with colors and icons.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @default_badge_color Elektrine.Theme.default_value("color_primary")
  @staff_badge_color Elektrine.Theme.default_value("color_error")
  @admin_badge_color Elektrine.Theme.default_value("color_error")
  @moderator_badge_color Elektrine.Theme.default_value("color_success")
  @supporter_badge_color Elektrine.Theme.default_value("color_warning")
  @developer_badge_color Elektrine.Theme.default_value("color_primary")
  @contributor_badge_color @default_badge_color
  @beta_tester_badge_color Elektrine.Theme.default_value("color_secondary")

  schema "user_badges" do
    field :badge_type, :string
    field :badge_text, :string
    field :badge_color, :string, default: @default_badge_color
    field :badge_icon, :string
    field :tooltip, :string
    field :position, :integer, default: 0
    field :visible, :boolean, default: true

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :granted_by, Elektrine.Accounts.User

    timestamps()
  end

  @badge_types ~w(verified supporter developer admin moderator contributor beta_tester staff custom)

  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [
      :user_id,
      :badge_type,
      :badge_text,
      :badge_color,
      :badge_icon,
      :tooltip,
      :granted_by_id,
      :position,
      :visible
    ])
    |> validate_required([:user_id, :badge_type])
    |> validate_inclusion(:badge_type, @badge_types)
    |> validate_format(:badge_color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a valid hex color")
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:granted_by_id)
  end

  def badge_types, do: @badge_types

  def default(field) when is_atom(field) do
    Map.get(%__MODULE__{}, field)
  end

  @doc """
  Returns default properties for a given badge type.
  """
  def default_badge_properties(badge_type) do
    case badge_type do
      "staff" ->
        %{
          badge_text: "Staff",
          badge_color: @staff_badge_color,
          badge_icon: "hero-check-badge",
          tooltip: "Elektrine Staff Member"
        }

      "verified" ->
        %{
          badge_text: "Verified",
          badge_color: @default_badge_color,
          badge_icon: "hero-check-badge",
          tooltip: "Verified Account"
        }

      "admin" ->
        %{
          badge_text: "Admin",
          badge_color: @admin_badge_color,
          badge_icon: "hero-check-badge",
          tooltip: "Administrator"
        }

      "moderator" ->
        %{
          badge_text: "Moderator",
          badge_color: @moderator_badge_color,
          badge_icon: "hero-shield-exclamation",
          tooltip: "Community Moderator"
        }

      "supporter" ->
        %{
          badge_text: "Supporter",
          badge_color: @supporter_badge_color,
          badge_icon: "hero-heart",
          tooltip: "Platform Supporter"
        }

      "developer" ->
        %{
          badge_text: "Developer",
          badge_color: @developer_badge_color,
          badge_icon: "hero-code-bracket",
          tooltip: "Developer"
        }

      "contributor" ->
        %{
          badge_text: "Contributor",
          badge_color: @contributor_badge_color,
          badge_icon: "hero-star",
          tooltip: "Platform Contributor"
        }

      "beta_tester" ->
        %{
          badge_text: "Beta Tester",
          badge_color: @beta_tester_badge_color,
          badge_icon: "hero-beaker",
          tooltip: "Beta Tester"
        }

      "custom" ->
        %{
          badge_text: "Custom",
          badge_color: @default_badge_color,
          badge_icon: nil,
          tooltip: "Custom Badge"
        }

      _ ->
        %{
          badge_text: "",
          badge_color: @default_badge_color,
          badge_icon: nil,
          tooltip: ""
        }
    end
  end
end
