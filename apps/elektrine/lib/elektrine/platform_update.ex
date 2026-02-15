defmodule Elektrine.PlatformUpdate do
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User

  schema "platform_updates" do
    field :title, :string
    field :description, :string
    field :badge, :string
    field :items, {:array, :string}, default: []
    field :published, :boolean, default: true

    belongs_to :created_by, User

    timestamps()
  end

  def changeset(update, attrs) do
    update
    |> cast(attrs, [:title, :description, :badge, :items, :published, :created_by_id])
    |> validate_required([:title, :description, :items])
    |> validate_length(:title, min: 1, max: 100)
    |> validate_length(:description, min: 1, max: 500)
    |> validate_length(:badge, max: 20)
    |> validate_items()
  end

  defp validate_items(changeset) do
    items = get_field(changeset, :items)

    if items && items != [] do
      # Validate each item
      valid_items =
        Enum.all?(items, fn item ->
          is_binary(item) && String.trim(item) != "" && String.length(item) <= 200
        end)

      if valid_items do
        changeset
      else
        add_error(
          changeset,
          :items,
          "each item must be a non-empty string with max 200 characters"
        )
      end
    else
      add_error(changeset, :items, "must have at least one item")
    end
  end
end
