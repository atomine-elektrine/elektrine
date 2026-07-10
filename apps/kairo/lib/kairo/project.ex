defmodule Kairo.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active archived)
  @max_name_length 255
  @max_slug_length 255
  @max_description_length 20_000

  schema "kairo_projects" do
    belongs_to :user, Elektrine.Accounts.User

    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :autonomy_level, :integer, default: 1

    has_many :sources, Kairo.Source

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:user_id, :name, :slug, :description, :status, :autonomy_level])
    |> maybe_put_slug()
    |> validate_required([:user_id, :name, :slug, :status, :autonomy_level])
    |> validate_length(:name, max: @max_name_length)
    |> validate_length(:slug, max: @max_slug_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:autonomy_level, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> unique_constraint(:slug, name: :kairo_projects_user_id_slug_index)
    |> foreign_key_constraint(:user_id)
  end

  defp maybe_put_slug(changeset) do
    case blank_to_nil(get_field(changeset, :slug)) do
      nil ->
        put_change(changeset, :slug, slugify(get_field(changeset, :name)))

      slug ->
        put_change(changeset, :slug, slugify(slug))
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  defp slugify(_value), do: "project"
end
