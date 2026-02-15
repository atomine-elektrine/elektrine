defmodule Elektrine.Social.LinkPreview do
  use Ecto.Schema
  import Ecto.Changeset

  schema "link_previews" do
    field :url, :string
    field :title, :string
    field :description, :string
    field :image_url, :string
    field :site_name, :string
    field :favicon_url, :string
    field :status, :string, default: "pending"
    field :error_message, :string
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :url,
      :title,
      :description,
      :image_url,
      :site_name,
      :favicon_url,
      :status,
      :error_message,
      :fetched_at
    ])
    |> validate_required([:url])
    |> validate_inclusion(:status, ["pending", "success", "failed"])
    |> validate_url(:url)
    |> unique_constraint(:url)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      uri = URI.parse(url)

      if uri.scheme in ["http", "https"] and uri.host do
        []
      else
        [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
