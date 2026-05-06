defmodule Elektrine.Profiles.ProfileWidget do
  @moduledoc """
  Schema for embeddable widgets on user profiles.
  Supports text, images, Spotify, YouTube, GitHub stats, and Discord status widgets with customizable settings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "profile_widgets" do
    field :widget_type, :string
    field :title, :string
    field :content, :string
    field :url, :string
    field :position, :integer, default: 0
    field :is_active, :boolean, default: true
    field :settings, :map, default: %{}

    belongs_to :profile, Elektrine.Profiles.UserProfile

    timestamps()
  end

  @widget_types ~w(text image spotify youtube github_stats discord_status)

  def changeset(widget, attrs) do
    widget
    |> cast(attrs, [
      :profile_id,
      :widget_type,
      :title,
      :content,
      :url,
      :position,
      :is_active,
      :settings
    ])
    |> validate_required([:profile_id, :widget_type])
    |> validate_inclusion(:widget_type, @widget_types)
    |> validate_length(:title, max: 200)
    |> validate_length(:content, max: 5000)
    |> validate_discord_status_content()
    |> foreign_key_constraint(:profile_id)
  end

  def widget_types, do: @widget_types

  defp validate_discord_status_content(changeset) do
    case {get_field(changeset, :widget_type), get_field(changeset, :content)} do
      {"discord_status", content} when is_binary(content) ->
        if String.match?(content, ~r/^[0-9]{17,20}$/) do
          changeset
        else
          add_error(changeset, :content, "must be a valid Discord user ID")
        end

      _ ->
        changeset
    end
  end
end
