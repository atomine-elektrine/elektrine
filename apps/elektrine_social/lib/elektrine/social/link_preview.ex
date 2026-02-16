defmodule Elektrine.Social.LinkPreview do
  use Ecto.Schema
  import Ecto.Changeset

  @max_varchar_length 255

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
    |> truncate_field(:title, @max_varchar_length)
    |> truncate_field(:site_name, @max_varchar_length)
    |> nilify_overlong_field(:image_url, @max_varchar_length)
    |> nilify_overlong_field(:favicon_url, @max_varchar_length)
    |> validate_required([:url])
    |> validate_inclusion(:status, ["pending", "success", "failed"])
    |> validate_url(:url)
    |> unique_constraint(:url)
  end

  defp truncate_field(changeset, field, max_length) do
    update_change(changeset, field, fn value ->
      if is_binary(value) and String.length(value) > max_length do
        String.slice(value, 0, max_length)
      else
        value
      end
    end)
  end

  defp nilify_overlong_field(changeset, field, max_length) do
    update_change(changeset, field, fn value ->
      if is_binary(value) and String.length(value) > max_length do
        nil
      else
        value
      end
    end)
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
