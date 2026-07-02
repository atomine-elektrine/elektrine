defmodule Elektrine.Accounts.ClientAppSetting do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "client_app_settings" do
    field :app, :string
    field :settings, :map, default: %{}

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:user_id, :app, :settings])
    |> update_change(:app, &normalize_app/1)
    |> validate_required([:user_id, :app, :settings])
    |> validate_length(:app, min: 1, max: 100)
    |> validate_format(:app, ~r/^[A-Za-z0-9_.:-]+$/,
      message: "may only contain letters, numbers, dots, underscores, colons, and hyphens"
    )
    |> validate_settings_map()
    |> unique_constraint([:user_id, :app])
    |> foreign_key_constraint(:user_id)
  end

  def normalize_app(app) when is_binary(app), do: String.trim(app)
  def normalize_app(app), do: app

  defp validate_settings_map(changeset) do
    case get_field(changeset, :settings) do
      settings when is_map(settings) -> changeset
      _ -> add_error(changeset, :settings, "must be a map")
    end
  end
end
